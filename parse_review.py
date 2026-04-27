import os
import sys
import re
import json
import argparse
import pdb
import subprocess
from bs4 import BeautifulSoup
from datetime import datetime
import shutil
import cssutils
import logging

# 禁用cssutils的日志输出
cssutils.log.setLevel(logging.CRITICAL)


def extract_style_rules(soup):
    """从HTML文档提取CSS样式规则"""
    style_rules = {}  # 存储简单类选择器
    compound_style_rules = {}  # 存储复合选择器，如.risk strong
    tag_style_rules = {}  # 存储标签选择器，如h3, h4

    for style in soup.find_all("style"):
        if not style.string:
            continue

        # 解析CSS样式表
        sheet = cssutils.parseString(style.string)
        for rule in sheet:
            if rule.type != rule.STYLE_RULE:
                continue

            selector = rule.selectorText
            style_dict = dict([(prop.name, prop.value) for prop in rule.style])

            # 处理逗号分隔的选择器
            if "," in selector:
                for sub_selector in selector.split(","):
                    sub_selector = sub_selector.strip()
                    process_selector(
                        sub_selector,
                        style_dict,
                        style_rules,
                        compound_style_rules,
                        tag_style_rules,
                    )
            else:
                process_selector(
                    selector,
                    style_dict,
                    style_rules,
                    compound_style_rules,
                    tag_style_rules,
                )

    return style_rules, compound_style_rules, tag_style_rules


def process_selector(
    selector, style_dict, style_rules, compound_style_rules, tag_style_rules
):
    """处理单个CSS选择器"""
    # 简单类选择器，如 .function
    if selector.startswith(".") and "." not in selector[1:] and " " not in selector:
        class_name = selector[1:]  # 去掉点号
        style_rules[class_name] = style_dict
    # 复合选择器，如 .risk strong
    elif " " in selector and selector.split(" ")[0].startswith("."):
        compound_style_rules[selector] = style_dict
    # 简单标签选择器，如 h3, p, ul
    elif (
        not selector.startswith(".")
        and not selector.startswith("#")
        and " " not in selector
    ):
        tag_style_rules[selector] = style_dict


def apply_style_to_element(element, styles):
    """将样式应用到单个元素"""
    current_style = element.get("style", "")
    inline_style = "; ".join([f"{name}: {value}" for name, value in styles.items()])

    if current_style:
        element["style"] = f"{current_style}; {inline_style}"
    else:
        element["style"] = inline_style


def apply_styles_to_soup(soup, style_rules, compound_style_rules, tag_style_rules):
    """将样式应用到HTML元素"""
    # 处理标签选择器
    for tag_name, styles in tag_style_rules.items():
        for element in soup.find_all(tag_name):
            apply_style_to_element(element, styles)

    # 处理复合选择器
    for selector, styles in compound_style_rules.items():
        parts = selector.split()
        if len(parts) != 2 or not parts[0].startswith("."):
            continue

        parent_class = parts[0][1:]  # 去掉点号
        child_tag = parts[1]

        # 在整个文档中找到父元素
        for parent in soup.find_all(class_=parent_class):
            # 找到子元素
            for element in parent.find_all(child_tag):
                apply_style_to_element(element, styles)

    # 处理简单的类选择器
    for class_name, styles in style_rules.items():
        for element in soup.find_all(class_=class_name):
            apply_style_to_element(element, styles)


def parse_review_html(html_file):
    """解析HTML代码审查报告并提取结构化数据（支持同一函数多条reviewComments合并）"""
    with open(html_file, "r", encoding="utf-8") as file:
        soup = BeautifulSoup(file, "html.parser")

    # 提取样式规则
    style_rules, compound_style_rules, tag_style_rules = extract_style_rules(soup)

    # 将样式应用到整个文档
    apply_styles_to_soup(soup, style_rules, compound_style_rules, tag_style_rules)

    # 用于合并相同函数的reviewComments
    merged_results = {}

    # 查找所有file-report-style div
    file_reports = soup.find_all("div", class_="file-report-style")

    for file_report in file_reports:
        # 提取文件路径
        file_path_header = file_report.find("h4", string="File Path:")
        if not file_path_header:
            continue

        file_path = file_path_header.find_next("p").text.strip()

        # 提取每个风险区域
        risk_divs = file_report.find_all("div", class_="risk")

        for risk_div in risk_divs:
            # 提取函数信息
            function_div = risk_div.find("div", class_="function")
            if not function_div:
                continue

            # 获取函数名和位置
            code_tag = function_div.find("code")

            # 提取行号范围，去掉括号
            function_text = function_div.get_text(" ", strip=True)
            location_match = re.search(r"\(lines\s+(\d+)\s*[-–]\s*(\d+)", function_text)
            function_location = ""
            if location_match:
                function_location = (
                    f"{location_match.group(1)}-{location_match.group(2)}"
                )

            if code_tag:
                function_name = code_tag.text.strip()
            else:
                # 兼容没有 <code> 标签的场景，如 “Function: xxx (lines a–b)”
                name_match = re.search(r"Function:\s*([^(]+)", function_text)
                if name_match:
                    function_name = name_match.group(1).strip()
                else:
                    continue

            if not function_location:
                # copy html_file to current directory with date suffix
                date_suffix = datetime.now().strftime("%Y%m%d_%H%M%S")
                backup_file_path = f"./{os.path.basename(html_file)}_{date_suffix}.bak"
                shutil.copy(html_file, backup_file_path)
                sys.exit(f"错误: 在文件 '{file_path}' 中未找到函数位置信息.")

            # 创建风险区域的副本以进行修改
            risk_clone = BeautifulSoup(str(risk_div), "html.parser")

            # 从副本中移除函数信息区域
            function_to_remove = risk_clone.find("div", class_="function")
            if function_to_remove:
                function_to_remove.decompose()

            # 输出HTML，保留原有样式
            review_html = str(risk_clone)

            # 合并逻辑
            key = (file_path, function_name, function_location)
            if key in merged_results:
                merged_results[key]["reviewComments"] += review_html
            else:
                merged_results[key] = {
                    "filePath": file_path,
                    "functionName": function_name,
                    "functionLocation": function_location,
                    "reviewComments": review_html,
                }

    # 转为列表输出
    results = sorted(
        merged_results.values(),
        key=lambda x: (
            x["filePath"],
            get_start_line(x["functionLocation"]),
        ),
    )
    return results


def get_start_line(location_str):
    """安全地提取函数位置的起始行号"""
    try:
        if "-" in location_str:
            return int(location_str.split("-")[0].strip())
        else:
            return int(location_str.strip())
    except ValueError:
        sys.exit(f"警告: 函数位置 '{location_str}' 格式不正确，无法排序。")


def extract_text_preserve_formatting(soup):
    """提取HTML文本内容，保留换行和代码块的缩进格式"""
    import textwrap
    import re

    result_parts = []

    def process_element(element):
        if element.name == "pre":
            # 代码块，使用 Markdown 格式包裹
            code_content = element.get_text()
            # 使用三个反引号包裹代码块，Gerrit 支持 Markdown 格式
            return "```\n" + code_content + "\n```\n\n"
        elif element.name in ["div"]:
            # 处理不同类型的div
            class_name = element.get("class", [])
            if "description" in class_name or "solution" in class_name:
                # description和solution div：提取文本并自动换行
                # 先处理内部的strong和code标签
                text_parts = []
                for child in element.children:
                    if child.name == "strong":
                        text_parts.append(child.get_text())
                    elif child.name == "code":
                        text_parts.append("`" + child.get_text() + "`")
                    elif child.name:
                        text_parts.append(child.get_text())
                    else:
                        text_parts.append(str(child))

                text_content = "".join(text_parts).strip()
                # 移除多余的空格
                text_content = re.sub(r"\s+", " ", text_content)
                # 按100字符换行，保持单词完整
                wrapped_text = textwrap.fill(
                    text_content,
                    width=100,
                    break_long_words=False,
                    break_on_hyphens=False,
                )
                return wrapped_text + "\n\n"
            elif "function" in class_name:
                # function div：处理Function标签和代码
                text_parts = []
                for child in element.children:
                    if child.name == "strong":
                        text_parts.append(child.get_text() + " ")
                    elif child.name == "code":
                        text_parts.append(child.get_text())
                    elif child.name:
                        text_parts.append(child.get_text())
                    else:
                        text_parts.append(str(child))

                text_content = "".join(text_parts).strip()
                return text_content + "\n\n"
            elif "example" in class_name:
                # example div：处理其内容
                text = ""
                for child in element.children:
                    if child.name == "strong":
                        # "Example Code:" 这样的标题
                        text += child.get_text(strip=True) + "\n\n"
                    elif child.name == "pre":
                        # 代码块
                        text += process_element(child)
                    elif child.name:
                        text += process_element(child)
                    else:
                        child_text = str(child).strip()
                        if child_text:
                            text += child_text + "\n"
                return text
            else:
                # 其他div，递归处理
                text = ""
                for child in element.children:
                    if child.name:
                        text += process_element(child)
                    else:
                        child_text = str(child).strip()
                        if child_text:
                            text += child_text + "\n"
                return text
        elif element.name in ["strong"]:
            # 加粗文本
            # 如果strong是风险级别标题（如"Major Risk (D1)"），添加换行
            text = element.get_text(strip=True)
            # 使用正则表达式匹配风险级别格式: Critical/Major/Minor Risk (大写字母+数字)
            # 例如: "Major Risk (D1)", "Critical Risk (A2)", "Minor Risk (E3)"
            risk_pattern = r"(Critical|Major|Minor)\s+(Risk|Issue)\s+\([A-Z]\d+\)"
            if (
                text
                and re.match(risk_pattern, text)
                and element.parent
                and element.parent.name == "div"
            ):
                # 这是一个标题级别的strong标签
                return text + "\n\n"
            else:
                # 普通的strong标签，不添加额外换行
                return text
        elif element.name in ["p", "h1", "h2", "h3", "h4", "h5", "h6"]:
            # 段落和标题，提取文本并换行
            text_content = element.get_text(strip=True)
            return text_content + "\n\n" if text_content else ""
        elif element.name == "br":
            return "\n"
        elif element.name:
            # 其他HTML元素，递归处理
            text = ""
            for child in element.children:
                if child.name:
                    text += process_element(child)
                else:
                    child_text = str(child).strip()
                    if child_text:
                        text += child_text
            return text
        else:
            # 纯文本节点
            return str(element)

    # 处理所有子元素
    for child in soup.children:
        if child.name:
            result_parts.append(process_element(child))
        else:
            text = str(child).strip()
            if text:
                result_parts.append(text)

    result_text = "".join(result_parts)

    # 最终清理：移除连续的空行，最多保留两个连续空行
    lines = result_text.split("\n")
    final_lines = []
    empty_count = 0

    for line in lines:
        if line.strip() == "":
            empty_count += 1
            if empty_count <= 2:
                final_lines.append("")
        else:
            empty_count = 0
            final_lines.append(line)

    # 去除开头和结尾的空行
    while final_lines and final_lines[0] == "":
        final_lines.pop(0)
    while final_lines and final_lines[-1] == "":
        final_lines.pop()

    return "\n".join(final_lines)


def execute_curl_command(curl_args, timeout_seconds=60):
    """执行curl命令并返回结果"""
    try:
        # 避免在日志中打印密码，只展示命令的大致形式
        safe_args = [
            arg if not arg.startswith("-u") else "-u ****" for arg in curl_args
        ]
        print(f"执行curl命令: {' '.join(safe_args)}")

        result = subprocess.run(
            curl_args,
            capture_output=True,
            text=True,
            timeout=timeout_seconds,
        )

        return {
            "returncode": result.returncode,
            "stdout": result.stdout.strip(),
            "stderr": result.stderr.strip(),
        }
    except subprocess.TimeoutExpired:
        return {"returncode": 28, "stdout": "", "stderr": "Request timeout"}
    except Exception as e:
        return {"returncode": -1, "stdout": "", "stderr": str(e)}


def push_comments_to_gerrit(
    change_num,
    username,
    password,
    comments_data,
    message="[GPT Review] Please address the following issues",
):
    """将comments推送到Gerrit"""

    # 构建Gerrit API URL
    gerrit_url = f"https://gerrit.company.example.com/gerrit/a/changes/{change_num}/revisions/current/review"

    # 转换review数据为Gerrit comments格式
    gerrit_payload = {"message": message, "comments": {}}

    # 将review_data转换为Gerrit期望的格式
    for review_item in comments_data:
        file_path = review_item["filePath"]
        function_location = review_item["functionLocation"]
        review_comments = review_item["reviewComments"]

        # 解析行号范围，使用起始行号作为comment位置
        try:
            start_line = get_start_line(function_location)
        except Exception:
            print(f"警告: 无法解析函数位置 {function_location}，跳过此条评论")
            continue

        # 从HTML中提取纯文本评论内容，保留格式
        soup = BeautifulSoup(review_comments, "html.parser")
        comment_text = extract_text_preserve_formatting(soup)

        if not comment_text:
            continue

        # 如果文件路径不在comments中，初始化为空列表
        if file_path not in gerrit_payload["comments"]:
            gerrit_payload["comments"][file_path] = []

        # 添加评论
        gerrit_payload["comments"][file_path].append(
            {"line": start_line, "message": comment_text}
        )

    # 如果没有有效的评论，返回成功但不执行推送
    if not gerrit_payload["comments"]:
        print("没有找到有效的评论内容，跳过推送")
        return True

    # 将payload转换为JSON字符串
    payload_json = json.dumps(gerrit_payload, ensure_ascii=False, indent=2)

    print("准备推送到Gerrit的评论数据:")
    print(f"- Change Number: {change_num}")
    print(f"- 涉及文件数: {len(gerrit_payload['comments'])}")
    total_comments = sum(
        len(comments) for comments in gerrit_payload["comments"].values()
    )
    print(f"- 总评论数: {total_comments}")

    # 构建curl命令
    curl_args = [
        "curl",
        "-X",
        "POST",
        "-u",
        f"{username}:{password}",
        "-H",
        "Content-Type: application/json",
        "-H",
        "User-Agent: AutoReview-Script/1.0",
        "--connect-timeout",
        "10",
        "--max-time",
        "60",
        "-d",
        payload_json,
        gerrit_url,
    ]

    # 添加代理设置（如果环境变量中有）
    proxy_url = (
        os.environ.get("https_proxy")
        or os.environ.get("HTTPS_PROXY")
        or os.environ.get("http_proxy")
        or os.environ.get("HTTP_PROXY")
    )

    if proxy_url:
        curl_args.extend(["--proxy", proxy_url])
        print(f"使用代理: {proxy_url}")

    # 执行curl命令
    result = execute_curl_command(curl_args)

    # 处理响应
    if result["returncode"] == 0:
        print("成功推送评论到Gerrit!")
        if result["stdout"]:
            print(f"服务器响应: {result['stdout']}")
        return True
    else:
        print(f"推送失败 (退出码: {result['returncode']})")
        if result["stderr"]:
            print(f"错误信息: {result['stderr']}")
        if result["stdout"]:
            print(f"响应内容: {result['stdout']}")
        return False


def main():
    parser = argparse.ArgumentParser(
        description="解析代码审查HTML并输出包含可直接查看HTML的JSON，支持推送到Gerrit"
    )
    parser.add_argument("html_file", help="HTML文件路径")
    parser.add_argument(
        "-o", "--output", help="输出JSON文件路径", default="review_output.json"
    )
    parser.add_argument(
        "--debug",
        action="store_true",
        help="启用调试模式，在程序开始和结束时进入调试器",
    )
    # Gerrit推送相关参数
    parser.add_argument(
        "--push-to-gerrit", action="store_true", help="将解析的评论推送到Gerrit"
    )
    parser.add_argument("--change-num", help="Gerrit变更编号 (例如: 12345)")
    parser.add_argument(
        "--gerrit-username", help="Gerrit用户名 (也可通过环境变量GERRIT_USERNAME设置)"
    )
    parser.add_argument(
        "--gerrit-password",
        help="Gerrit密码/API令牌 (也可通过环境变量GERRIT_PASSWORD设置)",
    )
    parser.add_argument(
        "--review-message",
        default="CompanyGPT/GHC review comments",
        help="推送到Gerrit的评论消息 (默认: 'CompanyGPT/GHC review comments')",
    )

    args = parser.parse_args()

    if not os.path.exists(args.html_file):
        sys.exit(f"错误: 文件 '{args.html_file}' 不存在.")

    # 验证Gerrit推送参数
    if args.push_to_gerrit:
        if not args.change_num:
            sys.exit("错误: 推送到Gerrit需要指定 --change-num 参数")

        # 获取认证信息（优先使用命令行参数，其次是环境变量）
        username = args.gerrit_username or os.environ.get("GERRIT_USERNAME")
        password = args.gerrit_password or os.environ.get("GERRIT_PASSWORD")

        if not username or not password:
            sys.exit(
                "错误: 推送到Gerrit需要提供用户名和密码/API令牌\n"
                "可通过 --gerrit-username 和 --gerrit-password 参数提供，\n"
                "或设置环境变量 GERRIT_USERNAME 和 GERRIT_PASSWORD"
            )

    review_data = parse_review_html(args.html_file)

    # 没有评论数据也是一种正确行为
    # if not review_data:
    #     sys.exit("警告: 未找到评论数据.")

    # 保存为JSON
    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(review_data, f, ensure_ascii=False, indent=2)

    print(f"成功解析 {len(review_data)} 条评论记录.")
    print(f"数据已保存到: {args.output}")

    # 如果启用了Gerrit推送
    if args.push_to_gerrit:
        print(f"开始推送评论到Gerrit (Change: {args.change_num})...")

        # 获取认证信息
        username = args.gerrit_username or os.environ.get("GERRIT_USERNAME")
        password = args.gerrit_password or os.environ.get("GERRIT_PASSWORD")
        print(f"- 使用的Gerrit用户名: {username}")
        print(f"- 使用的Gerrit密码: {password}")

        success = push_comments_to_gerrit(
            change_num=args.change_num,
            username=username,
            password=password,
            comments_data=review_data,
            message=args.review_message,
        )

        if success:
            print("✅ 成功推送评论到Gerrit!")
        else:
            sys.exit("❌ 推送到Gerrit失败!")

    # 如果开启debug模式，在程序结束前进入调试器并自动显示结果
    if args.debug:
        print("\n程序即将结束，进入调试器并自动显示结果...")

        # 创建自动执行命令的pdb实例
        debugger = pdb.Pdb()

        # 设置断点并自动执行命令
        def auto_debug_session():
            # 先显示结果预览
            print("\n=== review_data 预览 ===")
            if review_data and len(review_data) > 0:
                print(f"共解析出 {len(review_data)} 条记录")
                first_item = review_data[0]
                print("\n第一条记录:")
                print(f"文件路径: {first_item.get('filePath', 'N/A')}")
                print(f"函数名称: {first_item.get('functionName', 'N/A')}")
                print(f"函数位置: {first_item.get('functionLocation', 'N/A')}")
                print("评论内容: (HTML格式)")
                # 显示完整的评论内容
                print(first_item.get("reviewComments", ""))
            else:
                print("无数据")

            # 进入调试模式，等待用户输入
            debugger.set_trace()

        # 执行自动调试会话
        auto_debug_session()


if __name__ == "__main__":
    main()
