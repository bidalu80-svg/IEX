from pathlib import Path
root=Path(__file__).resolve().parents[1]
def read(p): return (root/p).read_text(encoding="utf-8-sig")
picker=read("Views/Providers/UnifiedModelPicker.swift")
header=read("Views/Providers/ModelPickerProviderHeader.swift")
quota=read("Providers/ProviderAPIQuota.swift")
checks=0
def check(condition,label):
 global checks
 assert condition,label
 checks+=1
 print("PASS:",label)
check("ModelPickerProviderHeader(" in picker and "Text(item.instance.label)" not in picker,"Provider title is inside the card rather than a disconnected section label")
check("ProviderInstanceDetailView(instanceId: provider.id)" in picker and ".id(provider.id)" in picker,"Edit opens the exact provider detail without dismissing the picker")
check("case .loaded(let quota)" in picker and "let amount = quota.displayAmount" in picker,"Only confirmed numeric balances reach the header")
check("if let amount, let quota" in header and "ProgressView" not in header,"Missing/unsupported/loading balance reserves no badge space")
check('Text("编辑")' in header and 'Button(action: onToggle)' in header,"Edit and collapse have separate buttons")
check('Button(action: onEdit)' in header and 'Color.red' in header,"Balance badge opens details and debt is red")
check('ViewThatFits' in header and 'VStack(alignment: .leading' in header,"Long provider names have a wrapped header fallback")
check("max(0, totalValue - $0)" not in quota,"Debt is never clamped to zero")
check("CFBooleanGetTypeID" in quota and "resolvedRemaining.isNaN" in quota,"Boolean and NaN payloads are not balances")
check("total_credits" in quota and "total_usage" in quota,"Credit APIs can report balance as credits minus usage")
check("signature(instance)" in quota and "< 300" in quota and "< 60" in quota,"Credential-aware cache and failure backoff avoid repeated probing")
check("activeRequests.count >= 3" in quota and "request.timeoutInterval = 8" in quota,"Automatic queries are bounded and concurrency-limited")
check(".task(id: item.instance)" in picker,"Provider configuration edits refresh their balance")
check(".secondarySystemBackground" in picker and 'Text("Model Groups").font(.headline' in picker,"Group and provider headers use the requested inset-card layout")
check(read("Ze.xcodeproj/project.pbxproj").count("/* ModelPickerProviderHeader.swift in Sources */")==2,"Shared header is compiled in app target")
print(f"Model picker header structure checks passed: {checks}")
