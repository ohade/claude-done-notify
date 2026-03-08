#!/usr/bin/env python3
"""Convert Claude's markdown output to clean Slack mrkdwn.

Reads raw markdown from stdin, writes Slack-friendly mrkdwn to stdout.
Handles: tables, task checkboxes, headers, HTML tags, filler lines.

Usage: echo "$RAW_TEXT" | python3 format-slack.py [--tldr] [--max-chars N] [--max-lines N]
  --tldr       Output 1-2 line summary (for push notifications)
  --max-chars  Truncate output to N chars (default: 800)
  --max-lines  Max non-empty lines to keep (default: 8)
"""
import sys
import re

MAX_LINES_DEFAULT = 8
MAX_CHARS_DEFAULT = 800


def parse_table(lines):
    """Convert markdown table lines to Slack-friendly format.

    Input:  | File | Change |
            |------|--------|
            | foo.java | renamed method |

    Output:  `foo.java` — renamed method
    """
    headers = [h.strip() for h in lines[0].strip().strip('|').split('|')]
    data_rows = []
    for line in lines[1:]:
        stripped = line.strip()
        if re.match(r'^[\s|:-]+$', stripped):
            continue
        cells = [c.strip() for c in stripped.strip('|').split('|')]
        data_rows.append(cells)

    if not data_rows:
        return []

    result = []
    num_cols = len(headers)

    if num_cols == 2:
        for cells in data_rows:
            c0 = cells[0] if len(cells) > 0 else ""
            c1 = cells[1] if len(cells) > 1 else ""
            if re.search(r'\.\w+[:.]|[A-Z][a-z]+[A-Z]', c0):
                result.append(f"  `{c0}` — {c1}")
            else:
                result.append(f"  *{c0}:* {c1}")
    else:
        for cells in data_rows:
            c0 = cells[0] if len(cells) > 0 else ""
            rest = [c for c in cells[1:] if c]
            rest_str = " | ".join(rest)
            if re.search(r'\.\w+[:.]|[A-Z][a-z]+[A-Z]', c0):
                result.append(f"  `{c0}` — {rest_str}")
            else:
                result.append(f"  *{c0}* — {rest_str}")

    return result


def clean_for_slack(raw_text, tldr=False, max_chars=MAX_CHARS_DEFAULT, max_lines=MAX_LINES_DEFAULT):
    """Convert markdown to Slack mrkdwn."""
    lines = raw_text.split('\n')
    output = []
    i = 0
    in_code_block = False
    content_lines = 0  # count non-empty lines for truncation

    while i < len(lines):
        line = lines[i]

        # Track code blocks — pass through unchanged
        if line.strip().startswith('```'):
            in_code_block = not in_code_block
            if not tldr:
                output.append(line)
            i += 1
            continue

        if in_code_block:
            if not tldr:
                output.append(line)
                content_lines += 1
            i += 1
            if content_lines >= max_lines:
                break
            continue

        stripped = line.strip()

        # Skip empty lines (collapse later)
        if not stripped:
            if output and output[-1] != '':
                output.append('')
            i += 1
            continue

        # Skip filler phrases
        if re.match(r'^(all done|here\'?s the summary|here\'?s what|let me|i\'?ll |done\.|sure[.,!]|okay[.,!])', stripped, re.I):
            i += 1
            continue

        # Detect table: line starts with | and has multiple |
        if stripped.startswith('|') and stripped.count('|') >= 3:
            table_lines = []
            while i < len(lines) and lines[i].strip().startswith('|'):
                table_lines.append(lines[i])
                i += 1

            if not tldr:
                converted = parse_table(table_lines)
                for row in converted:
                    if content_lines >= max_lines:
                        remaining = len(converted) - converted.index(row)
                        output.append(f"  _...and {remaining} more_")
                        break
                    output.append(row)
                    content_lines += 1
            else:
                data_count = sum(1 for l in table_lines
                               if not re.match(r'^[\s|:-]+$', l.strip())
                               and l.strip() != table_lines[0].strip())
                if data_count:
                    output.append(f"({data_count} items)")
            continue

        # Check line budget
        if content_lines >= max_lines:
            break

        # Strip markdown headers to bold
        header_match = re.match(r'^(#{1,4})\s+(.*)', stripped)
        if header_match:
            output.append(f"*{header_match.group(2)}*")
            content_lines += 1
            i += 1
            continue

        # Convert task checkboxes
        line = re.sub(r'^(\s*)- \[x\] ', r'\1:white_check_mark: ', line)
        line = re.sub(r'^(\s*)- \[/\] ', r'\1:hourglass_flowing_sand: ', line)
        line = re.sub(r'^(\s*)- \[ \] ', r'\1:black_small_square: ', line)

        # Strip HTML tags
        line = re.sub(r'<[^>]+>', '', line)

        # **text** → *text*
        line = re.sub(r'\*\*([^*]+)\*\*', r'*\1*', line)

        # Clean escaped backticks: \` → `
        line = line.replace('\\`', '`')

        output.append(line)
        content_lines += 1
        i += 1

    # Join and trim
    text = '\n'.join(output).strip()

    # Collapse multiple blank lines
    text = re.sub(r'\n{3,}', '\n\n', text)

    # Strip trailing empty lines
    text = text.rstrip()

    if tldr:
        meaningful = [l for l in text.split('\n') if l.strip()]
        tldr_text = ' '.join(meaningful[:2])
        tldr_text = tldr_text.replace('`', '')
        return tldr_text[:150]

    # Hard truncate to max_chars
    if len(text) > max_chars:
        text = text[:max_chars].rsplit('\n', 1)[0] + '\n...'

    return text


def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('--tldr', action='store_true')
    parser.add_argument('--max-chars', type=int, default=MAX_CHARS_DEFAULT)
    parser.add_argument('--max-lines', type=int, default=MAX_LINES_DEFAULT)
    args = parser.parse_args()

    raw = sys.stdin.read()
    if not raw.strip():
        if args.tldr:
            print("Task completed — check terminal for details.")
        sys.exit(0)

    result = clean_for_slack(raw, tldr=args.tldr, max_chars=args.max_chars, max_lines=args.max_lines)
    print(result)


if __name__ == '__main__':
    main()
