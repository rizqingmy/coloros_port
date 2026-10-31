#!/usr/bin/env python3
import os
import sys
import re
import argparse

class Colors:
    HEADER = '\033[95m'
    OKBLUE = '\033[94m'
    OKGREEN = '\033[92m'
    WARNING = '\033[93m'
    FAIL = '\033[91m'
    ENDC = '\033[0m'

class SmaliKit:
    def __init__(self, args):
        self.args = args
        self.target_method = args.method
        self.recursive = args.recursive

        # 匹配方法块的正则 (保持修复后的稳健版本)
        self.method_pattern = re.compile(
            r"(?P<header>^\s*\.method[^\n\r]*?%s[^\n\r]*)"
            r"(?P<body>.*?)"
            r"(?P<footer>^\s*\.end method)"
            % re.escape(self.target_method),
            re.DOTALL | re.MULTILINE
        )

    def log(self, message, color=Colors.ENDC):
        print(f"{color}{message}{Colors.ENDC}")

    def process_content(self, content, file_path):
        match = self.method_pattern.search(content)
        if not match:
            return content, False

        self.log(f"[*] Found method '{self.target_method}' in: {os.path.basename(file_path)}", Colors.OKBLUE)

        header = match.group('header')
        body = match.group('body')
        footer = match.group('footer')

        new_body = body
        is_modified = False

        # 1. -remake
        if self.args.remake:
            self.log(f"  -> Applying -remake...")
            remake_content = self.args.remake.replace('\\n', '\n')
            new_body = f"\n    {remake_content}\n"
            is_modified = True

        # 2. -rim (普通字符串替换)
        if self.args.replace_in_method:
            old_str, new_str = self.args.replace_in_method
            if old_str in new_body:
                self.log(f"  -> Applying -rim...")
                new_body = new_body.replace(old_str, new_str)
                is_modified = True

        # 3. -reg (新增：正则替换) !!!
        # 用法：-reg "正则模式" "替换模板"
        if self.args.regex_replace:
            pattern_str, repl_str = self.args.regex_replace
            # 编译正则
            pattern = re.compile(pattern_str)
            if pattern.search(new_body):
                self.log(f"  -> Applying -reg (Regex Replace)...")
                # 使用 re.sub 进行替换，支持 \1, \2 等反向引用
                new_body = pattern.sub(repl_str, new_body)
                is_modified = True
            else:
                self.log(f"  -> [WARNING] Regex pattern not found.", Colors.WARNING)

        # 4. -dim
        if self.args.delete_in_method:
            target_str = self.args.delete_in_method
            if target_str in new_body:
                self.log(f"  -> Applying -dim...")
                new_body = new_body.replace(target_str, "")
                is_modified = True

        # 5. -dm
        if self.args.delete_method:
            self.log(f"  -> Applying -dm...")
            return content.replace(match.group(0), ""), True

        # 6. -al
        if self.args.after_line:
            target_line, add_line = self.args.after_line
            if target_line in new_body:
                self.log(f"  -> Applying -al...")
                new_body = new_body.replace(target_line, f"{target_line}\n    {add_line}")
                is_modified = True

        # 7. -bl
        if self.args.before_line:
            target_line, add_line = self.args.before_line
            if target_line in new_body:
                self.log(f"  -> Applying -bl...")
                new_body = new_body.replace(target_line, f"    {add_line}\n{target_line}")
                is_modified = True

        if is_modified:
            modified_block = f"{header}{new_body}{footer}"
            if match.group(0) != modified_block:
                new_content = content.replace(match.group(0), modified_block, 1)
                self.log(f"  -> [SUCCESS] Saved.", Colors.OKGREEN)
                return new_content, True
            else:
                self.log(f"  -> [INFO] No changes needed.", Colors.WARNING)

        return content, False

    def walk_and_patch(self, path):
        if os.path.isfile(path):
            self.patch_file(path)
        elif os.path.isdir(path):
            if self.recursive:
                candidates = (
                    os.path.join(root, file)
                    for root, _, files in os.walk(path)
                    for file in files
                )
            else:
                candidates = (
                    os.path.join(path, file)
                    for file in sorted(os.listdir(path))
                )
            for candidate in candidates:
                if not candidate.endswith(".smali"):
                    continue
                if self.args.iname and self.args.iname not in os.path.basename(candidate):
                    continue
                self.patch_file(candidate)
        else:
            self.log(f"[ERROR] Path not found: {path}", Colors.FAIL)

    def patch_file(self, file_path):
        try:
            with open(file_path, 'r', encoding='utf-8', errors='ignore') as f:
                content = f.read()
            if self.target_method in content:
                new_content, patched = self.process_content(content, file_path)
                if patched:
                    with open(file_path, 'w', encoding='utf-8') as f:
                        f.write(new_content)
                    return True
        except Exception as e:
            self.log(f"[ERROR] processing {file_path}: {e}", Colors.FAIL)
        return False

def main():
    parser = argparse.ArgumentParser(description="Python smali_kit with Regex Support")

    parser.add_argument('-p', dest='path', required=True)
    parser.add_argument('-m', dest='method', required=True)

    parser.add_argument('-in', dest='iname')
    parser.add_argument('-remake', dest='remake')
    parser.add_argument('-rim', dest='replace_in_method', nargs=2)

    # 新增参数：-reg 正则表达式 替换内容
    parser.add_argument('-reg', dest='regex_replace', nargs=2, metavar=('PATTERN', 'REPLACEMENT'))

    parser.add_argument('-dim', dest='delete_in_method')
    parser.add_argument('-dm', dest='delete_method', action='store_true')
    parser.add_argument('-al', dest='after_line', nargs=2)
    parser.add_argument('-bl', dest='before_line', nargs=2)
    parser.add_argument('-recursive', dest='recursive', action='store_true')

    args = parser.parse_args()
    patcher = SmaliKit(args)
    patcher.walk_and_patch(args.path)

if __name__ == "__main__":
    main()
