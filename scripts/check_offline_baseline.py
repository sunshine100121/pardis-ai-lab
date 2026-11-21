"""Fail closed if Qwen/native/model/storage or F1 hosting drift from 0.2.0."""
import ast, json, pathlib, subprocess

BASE='b848d9920e59b0af7bed6d1d335ece6652987cc1'
ROOT=pathlib.Path(__file__).resolve().parents[1]
def git(*args):
    return subprocess.check_output(['git',*args],cwd=ROOT)
# Keep the native inference engine, original model location and bridge byte-for-byte protected.
# M11-M19 intentionally add DB tables and limited hosting/model/settings code.
# Review only these five exact blobs; every further edit fails closed until re-reviewed.
APPROVED_034_BLOBS = {
    "lib/data/local/database/app_database.dart": "b32a76ac58fb6a17b8e7bd2bcd5541ea72dc8a75",
    "lib/features/hosting/lan_probe_runner.dart": "55dbb6a58ad449bbd05525e4a08aa524fb5145dd",
    "lib/features/hosting/presentation/device_hosting_provider.dart": "dfe7df4f80d738b362c699083bf1b9bfa318b456",
    "lib/features/models/presentation/providers/model_manager_provider.dart": "5dc5ab12ceef1f96144cf096d344b8c420728361",
    "lib/features/settings/domain/entities/inference_settings.dart": "6795ebe5d6a717c9bc809abdb8c2cb0d1c1fd726",
}
# M09 Vosk ZIP import requires two reviewed storage changes: allowing .zip
# filenames and updating the validation message. Only this exact blob is
# accepted; GGUF/native paths and every other protected file stay unchanged.
APPROVED_STT_ZIP_STORAGE_BLOB = 'e9489641589dbec6b02949c86965e5748dde24f0'
assert git('hash-object','lib/data/storage/model_storage.dart').decode().strip() == APPROVED_STT_ZIP_STORAGE_BLOB, 'UNREVIEWED_STT_ZIP_STORAGE_CHANGE'
protected=['lib/inference','native',
           'lib/core/platform/device_info.dart','lib/core/storage/app_directories.dart',
           'android/app/src/main/kotlin/app/ondevicellm/ondevice_llm/NativeBridge.kt']
assert not git('diff',BASE,'--',*protected).strip(), 'PROTECTED_RUNTIME_DRIFT'
reviewed_paths=list(APPROVED_034_BLOBS)
changed=set(git('diff','--name-only',BASE,'--',
                'lib/data/local/database','lib/features/hosting',
                'lib/features/models/presentation/providers/model_manager_provider.dart',
                'lib/features/settings/domain/entities/inference_settings.dart').decode().splitlines())
assert changed==set(reviewed_paths), 'UNREVIEWED_STORAGE_HOSTING_OR_SETTINGS_DIFF'
for path,expected_blob in APPROVED_034_BLOBS.items():
    assert git('hash-object',path).decode().strip()==expected_blob, 'REVIEWED_BLOB_CHANGED:'+path
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
compatibility_paths=git('ls-tree','-r','--name-only','5663b264afb77026014f81b69e04b1d00ab8a098','--',
    'lib/data/local/database','lib/data/storage/model_storage.dart','lib/core/storage/app_directories.dart',
    'lib/features/settings/domain/entities/inference_settings.dart',
    'lib/features/settings/presentation/providers/settings_provider.dart',
    'lib/features/settings/data/remote_key_store.dart',
    'lib/features/models/presentation/providers/model_manager_provider.dart',
    'lib/features/backup/local_backup_service.dart','pubspec.lock').decode().splitlines()
assert compatibility_paths
for path in compatibility_paths:
    if path in APPROVED_034_BLOBS:
        continue  # Exact reviewed blob SHA pinned above; additive changes covered by dedicated tests.
    if path == 'lib/data/storage/model_storage.dart':
        # Exact reviewed STT ZIP delta pinned above, not a broad bypass.
        continue
    installed=git('show','5663b264afb77026014f81b69e04b1d00ab8a098:'+path)
    installed=installed.replace(b'\r\n',b'\n')
    if path == 'lib/features/settings/domain/entities/inference_settings.dart':
        old=b"""      listeningModel: text('listeningModel', 32) == 'parakeet-v3'
          ? 'parakeet-v3'
          : '',"""
        new=b"""      listeningModel: switch (text('listeningModel', 32)) {
        'parakeet-v3' => 'parakeet-v3',
        'android-local' => 'android-local',
        'whisper-fa' => 'whisper-fa',
        'vosk-fa' => 'vosk-fa',
        _ => '',
      },"""
        assert installed.count(old)==1, 'UNEXPECTED_INSTALLED_SETTINGS_BASELINE'
        installed=installed.replace(old,new,1)
        format_old=b"""              [
                for (var i = 0; i < a.length; i++) same(a[i], b[i]),
              ].every((x) => x)"""
        format_new=b"""              [for (var i = 0; i < a.length; i++) same(a[i], b[i])]
                  .every((x) => x)"""
        assert installed.count(format_old)==1, 'UNEXPECTED_SETTINGS_FORMAT_BASELINE'
        installed=installed.replace(format_old,format_new,1)
    assert (ROOT/path).read_bytes().replace(b'\r\n',b'\n')==installed, 'INSTALL_STORAGE_SETTINGS_OR_DEPENDENCY_DIFF:'+path
print(json.dumps({'runtime_baseline':'PASS','f1_absent':'PASS','persian_334_keys':'PASS',
                  'installed_model_path_and_database_source_compatibility':'PASS',
                  'reviewed_m11_m19_blobs':'PINNED',
                  'device_database_migration':'NOT_VERIFIED'}))
