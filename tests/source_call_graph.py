from pathlib import Path
import re

def functions(s):
 clean=re.sub(r'//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'',lambda m:' '+''.join('\n' if c=='\n' else ' ' for c in m[0][1:]),s)
 defs={}
 for m in re.finditer(r'(?m)^\s*(?:void|bool|int|double|string|datetime|ulong|long|ENUM_\w+)\s+(\w+)\s*\([^;{}]*\)\s*\{',clean):
  begin=clean.index('{',m.start());depth=1;i=begin+1
  while depth:
   if clean[i]=='{':depth+=1
   if clean[i]=='}':depth-=1
   i+=1
  defs[m[1]]=(begin+1,i-1,clean[begin+1:i-1])
 return defs

def graph(s):
 defs=functions(s)
 return {name:set(re.findall(r'\b(\w+)\s*\(',body))&defs.keys() for name,(_,_,body) in defs.items()}
def cycles(g):
 seen=set();stack=[];active=set();result=[]
 def visit(n):
  if n in active:
   result.append(stack[stack.index(n):]+[n]);return
  if n in seen:return
  active.add(n);stack.append(n)
  for nxt in sorted(g[n]):visit(nxt)
  stack.pop();active.remove(n);seen.add(n)
 for n in g:visit(n)
 return result
if __name__=='__main__':
 import sys
 s=Path(sys.argv[1]).read_text();g=graph(s)
 for cycle in cycles(g):print(' -> '.join(cycle))
 print(len(g),'functions')
