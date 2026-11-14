"""Fail closed if Qwen/native/model/storage or F1 hosting drift from 0.2.0."""
import ast, json, pathlib, subprocess

BASE='b848d9920e59b0af7bed6d1d335ece6652987cc1'
ROOT=pathlib.Path(__file__).resolve().parents[1]
def git(*args):
    return subprocess.check_output(['git',*args],cwd=ROOT)
protected=['lib/inference','native','lib/data/local/database','lib/data/storage/model_storage.dart',
           'lib/core/platform/device_info.dart','lib/core/storage/app_directories.dart',
           'lib/features/hosting','android/app/src/main/kotlin/app/ondevicellm/ondevice_llm/NativeBridge.kt']
assert not git('diff',BASE,'--',*protected).strip(), 'PROTECTED_RUNTIME_DRIFT'
for name in ('PalaRuntime.kt','PalaHostService.kt','PalaDiagnostics.kt'):
    assert not list((ROOT/'android').rglob(name)), 'F1_CODE_PRESENT'
activity=(ROOT/'android/app/src/main/kotlin/app/ondevicellm/ondevice_llm/MainActivity.kt').read_text(encoding='utf-8')
for forbidden in ('PalaRuntime','shouldDestroyEngineWithHost','provideFlutterEngine','PARTIAL_WAKE_LOCK'):
    assert forbidden not in activity, forbidden
en=json.loads((ROOT/'lib/l10n/app_en.arb').read_text(encoding='utf-8'))
fa=json.loads((ROOT/'lib/l10n/app_fa.arb').read_text(encoding='utf-8'))
assert fa['@@locale']=='fa'
assert all(key in fa for key in en)
tree=ast.parse((ROOT/'docs/provenance/apply_020_overlay.py').read_text(encoding='utf-8'))
translations=next(ast.literal_eval(n.value) for n in tree.body if isinstance(n,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='translations' for t in n.targets))
assert len(translations)==334 and all(fa[k]==v for k,v in translations.items())
for path in ('lib/data/storage/model_storage.dart','lib/data/local/database/app_database.dart'):
    installed=git('show','5663b264afb77026014f81b69e04b1d00ab8a098:'+path)
    assert (ROOT/path).read_bytes().replace(b'\r\n',b'\n')==installed.replace(b'\r\n',b'\n'), 'INSTALL_STORAGE_SCHEMA_DIFF'
print(json.dumps({'runtime_baseline':'PASS','f1_absent':'PASS','persian_334_keys':'PASS',
                  'installed_model_path_and_database_source_compatibility':'PASS',
                  'device_database_migration':'NOT_VERIFIED'}))
