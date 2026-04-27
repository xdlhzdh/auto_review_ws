#!/bin/bash

# 确保脚本接收两个参数：HTML 文件路径和评论 JSON 文件路径
if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <html_file> <comments_json> <out_html>"
    exit 1
fi

HTML_FILE=$1
COMMENTS_JSON=$2

if [ ! -f "$HTML_FILE" ]; then
    echo "HTML file not found: $HTML_FILE"
    exit 1
fi

if [ ! -f "$COMMENTS_JSON" ]; then
    echo "Comments JSON file not found: $COMMENTS_JSON"
    exit 1
fi


# 调用 parse_diff_html.js 并传递 HTML 和评论内容
node -e "
const { JSDOM } = require('jsdom');
const fs = require('fs');

// 解析命令行参数
const htmlContent = fs.readFileSync('$HTML_FILE', 'utf8');
const comments = JSON.parse(fs.readFileSync('$COMMENTS_JSON', 'utf8'));

// 定义 parseDiffLine 函数
function parseDiffLine(diffLine) {
    const regex = /@@ -(\d+),(\d+) \+(\d+),(\d+) @@/;
    const match = diffLine.match(regex);
    if (!match) {
        throw new Error('Invalid diff line format');
    }
    const newStartLine = parseInt(match[3], 10);
    const newLineCount = parseInt(match[4], 10);
    const newEndLine = newStartLine + newLineCount - 1;
    return [newStartLine, newEndLine];
}

// 定义 processDiffHtml 函数
function processDiffHtml(html, comments) {
    const dom = new JSDOM(html);
    const document = dom.window.document;

    const diffLines = document.querySelectorAll('td.d2h-info .d2h-code-side-line');
    diffLines.forEach(line => {
        if (line.textContent?.includes('@@')) {
            const fileWrapper = line.closest('.d2h-file-wrapper');
            const fileHeader = fileWrapper?.querySelector(':scope > .d2h-file-header');
            const fileName = fileHeader?.querySelector('.d2h-file-name');
            const filePath = fileName?.textContent?.trim();
            if (!filePath) return;

            const [newStart, newEnd] = parseDiffLine(line.textContent);
            const fileComments = comments.filter(comment => comment.file_path === filePath);
            const fileCommentsInRange = fileComments.filter(comment => {
                const [start, end] = comment.function_location.split('-').map(Number);
                return start === newStart && end === newEnd;
            });

            if (fileCommentsInRange.length > 0) {
                const filesDiffContainer = line.closest('.d2h-files-diff');
                const leftSideDiffContainer = filesDiffContainer?.querySelector('.d2h-file-side-diff');
                const leftSideChangeLines = leftSideDiffContainer?.querySelectorAll('td.d2h-info .d2h-code-side-line');
                let leftSideChangeIndex = -1;

                leftSideChangeLines?.forEach((td, index) => {
                    if (td.textContent?.includes(\`+\${newStart}\`)) {
                        leftSideChangeIndex = index;
                    }
                });

                if (leftSideChangeIndex >= 0) {
                    const rightSideDiffContainer = filesDiffContainer?.querySelectorAll('.d2h-file-side-diff')[1];
                    const rightSideChangeLines = rightSideDiffContainer?.querySelectorAll('td.d2h-info .d2h-code-side-line');
                    const rightSideChangeLine = rightSideChangeLines?.item(leftSideChangeIndex);
                    const rightSideChangeLineNumber = rightSideChangeLine?.closest('td.d2h-info')?.previousElementSibling;
                    if (rightSideChangeLineNumber) {
                        const button = document.createElement('button');
                        button.textContent = 'Review';
                        button.className = 'hunk-comment-button relative mx-0 my-1 px-1 py-0 bg-cyan-500 text-white rounded-md';
                        rightSideChangeLineNumber.appendChild(button);
                    }
                }
            }
        }
    });

    return dom.serialize();
}

// 调用 processDiffHtml 函数并输出结果
const result = processDiffHtml(htmlContent, comments);
fs.writeFileSync('$OUT_HTML', result);
"
echo "Output written to $OUT_HTML"