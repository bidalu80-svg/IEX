#!/usr/bin/env python3
"""Compile actual production matching, navigation and Markdown text projection."""
import pathlib,subprocess,tempfile,shutil
root=pathlib.Path(__file__).resolve().parents[1]
source=(root/'Views/Chat/ChatSearch.swift').read_text(encoding='utf-8')
def section(begin,end):return source[source.index(begin):source.index(end)]
parser=(root/'Agent/Markdown/ZeMarkdownParser.swift').read_text(encoding='utf-8').split('// MARK: - MarkdownContent')[0]
parser='\n'.join(x for x in parser.splitlines() if not x.startswith('import cmark'))
text=parser+'\n'+section('// BEGIN chat-search-engine','// END chat-search-engine')+'\n'+section('// BEGIN chat-search-markdown-text','// END chat-search-markdown-text')+'\n'+(root/'scripts/ChatSearchEngineChecks.swift').read_text(encoding='utf-8')
compiler=shutil.which('swiftc')
if not compiler:raise SystemExit('swiftc required: run on the macOS workflow')
with tempfile.TemporaryDirectory(prefix='ze-search-') as directory:
    path=pathlib.Path(directory); (path/'main.swift').write_text(text,encoding='utf-8')
    subprocess.run([compiler,str(path/'main.swift'),'-o',str(path/'checks')],check=True)
    subprocess.run([str(path/'checks')],check=True)
