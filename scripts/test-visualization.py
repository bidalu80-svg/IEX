#!/usr/bin/env python3
"""Compile real data validation and type-check actual UIKit UI against iOS 16."""
from pathlib import Path
import platform
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
model = root / 'Agent/Visualization/VisualizationDocument.swift'
ui = root / 'Views/Chat/Visualization/VisualizationAttachment.swift'
with tempfile.TemporaryDirectory(prefix='ze-visualization-') as directory:
    work = Path(directory)
    binary = work / 'visualization-tests'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(model),
                    str(root / 'scripts/VisualizationCoreHarness.swift'), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
    stub = work / 'RendererCacheBoundary.swift'
    stub.write_text('import UIKit\n@MainActor enum SelectableMarkdownView { static func clearVisualizationCaches() {} }\n')
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
    target = ('arm64' if platform.machine() == 'arm64' else 'x86_64') + '-apple-ios16.0-simulator'
    subprocess.run(['xcrun', 'swiftc', '-typecheck', '-sdk', sdk, '-target', target,
                    str(model), str(ui), str(stub)], check=True)
    print('Visualization: production UIKit components type-checked for iOS 16.0')
