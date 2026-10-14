"""Verify source synchronization and extracted executable stop tests, without changing files."""
from pathlib import Path
import json,re,subprocess,tempfile,hashlib
root=Path(__file__).resolve().parents[1]
s=(root/'SEGS_Trade_Manager_Pro_v3.75.mq5').read_text()
assert all(p.read_text()==s for p in root.rglob('*.mq5'))
ts=(root/'src/data/mql5Code.ts').read_text()
assert json.loads(ts.split(' = ',1)[1].split(';\nexport default',1)[0])==s
assert s.count('allowAutoTrade=false')==1
# Regression: removed GBPUSD branch must not leave either undeclared reference.
assert not re.search(r'\bisGBPUSD\b', s)
assert 'bestTP2 = 1.33200' not in s and 'bestTP3 = 1.33690' not in s
assert 'if(InpAutoMapTP3ToOpposingLiquidity)' in s
assert 'void RunAdvisorStrategyEngine(bool forceScan, bool allowAutoTrade)\n{' in s
assert not re.search(r'if\([^\n]*GetSafestStructuralStopLoss',s)
a=s.index('bool SEGSSelectActiveOrderBlock(')
b=s.index('//+------------------------------------------------------------------+',s.index('double GetSafestStructuralStopLoss(',a))
assert s[a:b] in (root/'tests/structural_stop_test.cpp').read_text(), 'Harness must use current EA functions'
a_reset=s.index('bool SEGSResetExpiredSetup(string sym)\n{');b_reset=s.index('\nvoid CancelUnviablePlannedEntry',a_reset)
assert s[a_reset:b_reset] in (root/'tests/expired_signal_test.cpp').read_text()
assert 'SERIES_SYNCHRONIZED' in s and 'BarsCalculated(handles[h])' in s
init=s[s.index('int OnInit()'):s.index('void ReleaseIndicatorHandles()')]
assert 'RunAdvisorStrategyEngine(' not in init and 'return(INIT_SUCCEEDED)' in init
assert 'CopyRates(_Symbol, frames[i], 0, minimums[i], bootstrap)' in s
assert 'input ENUM_SEGS_SL_STYLE InpStructuralStopStyle = SL_STYLE_AUTO_DUAL;' in s
assert 'if(!MathIsValidNumber(pipSize) || pipSize <= 0.0) return tp;' in s
assert s.count('!MathIsValidNumber(tickVal) || tickVal <= 0.0) return 0.0;') >= 2
assert 'SEGS_DASH_VIS_' in s and 'SEGS_SYNC_SYS' in s
clean=re.sub(r'//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'','',s)
stack=[]
for c in clean:
 if c in '({[':stack.append(c)
 elif c in ')}]':assert stack and stack.pop()=={')':'(',']':'[','}':'{'}[c]
assert not stack
with tempfile.TemporaryDirectory() as tmp:
 for name in ['structural_stop_test','stop_guard_regression','expired_signal_test']:
  target=str(Path(tmp)/name)
  subprocess.run(['g++','-std=c++17','-Wall','-Wextra','-Werror',str(root/'tests'/f'{name}.cpp'),'-o',target],check=True)
  subprocess.run([target],check=True)
print('Source synchronization, current-function extraction, syntax regressions, and harness checks passed.')
print('Native MetaEditor/MT5 compilation and runtime validation are not included.')
