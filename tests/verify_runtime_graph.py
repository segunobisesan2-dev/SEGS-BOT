"""Reject recursive EA call paths, including scanner/HUD stack-overflow regression.

This is a source call-graph check, not native MQL5 compilation/runtime validation.
"""
from pathlib import Path
import re
import sys


def check_source(source):
    clean = re.sub(r'//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"',
                   lambda m: '\n' * m.group().count('\n'), source)
    functions = {}
    for match in re.finditer(r'^\w+\s+(\w+)\s*\([^;{}]*\)\s*\{', clean, re.M):
        start = end = match.end()
        depth = 1
        while depth:
            if clean[end] == '{': depth += 1
            if clean[end] == '}': depth -= 1
            end += 1
        functions[match[1]] = set(re.findall(r'\b(\w+)\s*\(', clean[start:end-1]))
    assert 'DrawSentimentHUD' in functions and 'ScanMarketStructureAndAdvice' in functions
    assert not functions['DrawSentimentHUD'] & {
        'ScanMarketStructureAndAdvice', 'RunAdvisorStrategyEngine',
        'CheckAndAutoTradeAdvice', 'ExecuteAdvisedTrade', 'UpdateUnifiedStrategyMatrix'
    }, 'HUD must render snapshots without strategy evaluation or execution'
    visited, active = set(), []

    def visit(name):
        assert name not in active, 'Recursive EA calls: ' + ' -> '.join(active + [name])
        if name in visited: return
        active.append(name)
        for child in sorted(functions[name] & functions.keys()): visit(child)
        active.pop()
        visited.add(name)

    for name in functions: visit(name)
    return len(functions)


if __name__ == '__main__':
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1] / 'SEGS_Trade_Manager_Pro_v3.76.mq5'
    count = check_source(path.read_text())
    print(f'No recursive call paths across {count} EA functions; HUD snapshot-only regression passed.')
