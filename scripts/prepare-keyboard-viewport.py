#!/usr/bin/env python3
"""Compile the unchanged keyboard host and collection-view subclass in isolation."""
from pathlib import Path
import sys, hashlib, json, importlib.util
sys.dont_write_bytecode = True
root = Path(__file__).resolve().parents[1]
work = Path(sys.argv[1]); work.mkdir(parents=True, exist_ok=True)
paths = ['Views/Chat/ChatKeyboardViewport.swift', 'Agent/MessageList/MessageListInfrastructure.swift', 'scripts/KeyboardViewportHarness.swift', 'scripts/KeyboardViewportUITests.swift']
sources = {p: (root/p).read_text(encoding='utf-8') for p in paths}
collection = sources[paths[1]].split('final class NoAnimationCollectionView: UICollectionView {', 1)[1].split('// MARK: - MessageListViewController', 1)[0]
production = sources[paths[0]] + '\nfinal class NoAnimationCollectionView: UICollectionView {' + collection
(work/'KeyboardViewport.swift').write_text(production + '\n' + sources[paths[2]], encoding='utf-8')
(work/'sources.json').write_text(json.dumps({'sha256': {p: hashlib.sha256((root/p).read_bytes()).hexdigest() for p in paths}, 'scope': 'Unchanged production keyboard viewport and NoAnimationCollectionView. Fixture message data/layout and SwiftUI composer; not the complete AIChatView or third-party IME. Real UIKit keyboard and XCTest interaction.'}, indent=2))
spec = importlib.util.spec_from_file_location('driver', root/'scripts/share-xcui-driver.py'); module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
module.DRIVER = sources[paths[3]]; module.write_project(work/'driver')
print(work)
