#!/usr/bin/env python3
"""Package archives produced by build.zig; never compile a second source tree."""
from pathlib import Path
import hashlib,os,plistlib,shutil,subprocess,sys,tempfile
ROOT=Path(__file__).resolve().parent.parent
os.chdir(ROOT)
ARTIFACTS=ROOT/'pkg/apple/artifacts'
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def core_inputs():
 return sorted([p for folder in ['src','include','resources/shaders'] for p in Path(folder).rglob('*') if p.is_file()]+[Path(p) for p in ['build.zig','build.zig.zon','tools/package-apple.py','LICENSE']])
def package(name,archive,headers,module,licenses,provenance):
 with tempfile.TemporaryDirectory(prefix='package-',dir=ROOT/'.build') as tmp:
  tmp=Path(tmp);framework=tmp/(name+'.framework');version=framework/'Versions/A'
  for directory in ['Headers','Modules','Resources']:(version/directory).mkdir(parents=True)
  shutil.copyfile(archive,version/name)
  for header in headers:shutil.copyfile(header,version/'Headers'/header.name)
  (version/'Modules/module.modulemap').write_text(module)
  (version/'Resources/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleExecutable=name,CFBundleIdentifier='com.beribeli.libmaspice.'+name,CFBundleName=name,CFBundlePackageType='FMWK',CFBundleShortVersionString='1.0',CFBundleVersion='1',MinimumOSVersion='26.0')))
  (framework/'Versions/Current').symlink_to('A')
  for item in [name,'Headers','Modules','Resources']:(framework/item).symlink_to('Versions/Current/'+item)
  staged=tmp/(name+'.xcframework')
  subprocess.run(['xcodebuild','-create-xcframework','-framework',str(framework),'-output',str(staged)],check=True)
  (staged/'Licenses').mkdir()
  for source,dest in licenses:shutil.copyfile(source,staged/'Licenses'/dest)
  provenance += ['Archive SHA-256: '+digest(archive)]
  (staged/'BUILD_PROVENANCE.txt').write_text('\n'.join(provenance)+'\n')
  dest=ARTIFACTS/staged.name
  # Replace only the generated artifact after staging and manifest complete.
  if dest.exists():shutil.rmtree(dest)
  shutil.move(staged,dest)
def main():
 if len(sys.argv)!=3:raise SystemExit('usage: package-apple.py CORE_ARCHIVE QUIC_ARCHIVE (normally zig build xcframework)')
 (ROOT/'.build').mkdir(exist_ok=True);ARTIFACTS.mkdir(parents=True,exist_ok=True)
 # The graph only offers safe modes; packaging requires the documented ReleaseSafe build.
 config=['Configuration: Zig 0.17.0 ReleaseSafe; arm64; macOS=26.0; C/ObjC -O2 -Wall -Wextra -Werror; deterministic archive',subprocess.check_output(['xcrun','clang','--version'],text=True).splitlines()[0],'macOS SDK: '+subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-version'],text=True).strip()]
 quic=Path('pkg/quic');inputs=[quic/n for n in ['codec.zig','random.zig','abi.zig','adapter.c','quic.h','shim.h','COPYING','ZIG-LICENSE']]
 package('CSpiceQUIC',Path(sys.argv[2]),[quic/'shim.h',quic/'quic.h'],'framework module CSpiceQUIC {\n  header "shim.h"\n  header "quic.h"\n  export *\n}\n',[(quic/'COPYING','spice-common-COPYING'),(quic/'ZIG-LICENSE','Zig-MIT')],['Implementation: pkg/quic; production Zig codec plus thin C ABI/error adapter','Upstream: spice-common 71e45706981973014eaab3d4b533d35d79e19ffa','Source: https://gitlab.freedesktop.org/spice/spice-common/-/archive/71e45706981973014eaab3d4b533d35d79e19ffa/spice-common-71e45706981973014eaab3d4b533d35d79e19ffa.tar.gz','Upstream archive SHA-256: f5cf6afab9a224fc34ff7cd578897a5769ac80aeeff54ddc937506de4628d69e']+config+['Owned source SHA-256: '+digest(p)+' '+str(p) for p in inputs])
 package('CSpiceZig',Path(sys.argv[1]),sorted(Path('include').glob('*.h')),Path('include/module.modulemap').read_text().replace('module CSpiceZig','framework module CSpiceZig',1),[(Path('LICENSE'),'SwiftSpice-MIT'),(quic/'ZIG-LICENSE','Zig-MIT')],['Implementation: src; owned Zig core and src/platform/apple native bridges','External static dependencies: CTurboJPEG, CSpiceQUIC, CUSBRedir; Apple SDK frameworks and system zlib']+config+['Owned source SHA-256: '+digest(p)+' '+str(p) for p in core_inputs()])
if __name__=='__main__':main()
