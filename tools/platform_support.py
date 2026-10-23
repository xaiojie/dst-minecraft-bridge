"""Platform discovery and argument arrays; importing this module has no effects."""
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys


def platform_name():
    if sys.platform=='win32':return 'windows'
    if sys.platform=='darwin':return 'macos'
    return 'unsupported'


def default_assets(platform=None,environment=None):
    environment=os.environ if environment is None else environment
    if (platform or platform_name())=='windows':
        return Path(environment.get('APPDATA',str(Path.home()/'AppData/Roaming')))/'.minecraft/assets'
    return Path.home()/'Downloads/.minecraft/assets'


def steam_root(platform=None):
    if (platform or platform_name())!='windows':return Path.home()/'Library/Application Support/Steam'
    import winreg
    for hive,key,value in ((winreg.HKEY_CURRENT_USER,r'Software\Valve\Steam','SteamPath'),
                           (winreg.HKEY_LOCAL_MACHINE,r'SOFTWARE\WOW6432Node\Valve\Steam','InstallPath')):
        try:
            with winreg.OpenKey(hive,key)as registry:return Path(winreg.QueryValueEx(registry,value)[0])
        except OSError:pass
    raise ValueError('steam_install_not_found')


def native_library(root,platform=None):
    if (platform or platform_name())=='windows':return Path(root)/'native/build-windows/dstmc_bridge.dll'
    return Path(root)/'native/build/libdstmc_probe.dylib'


def pe_info(path):
    with Path(path).open('rb')as stream:
        header=stream.read(64)
        if len(header)!=64 or header[:2]!=b'MZ':raise ValueError('invalid_pe_header')
        offset=struct.unpack_from('<I',header,60)[0]
        if offset<64 or offset>16*1024*1024:raise ValueError('invalid_pe_offset')
        stream.seek(offset);pe=stream.read(26)
    if len(pe)!=26 or pe[:4]!=b'PE\0\0':raise ValueError('invalid_pe_signature')
    machine=struct.unpack_from('<H',pe,4)[0];magic=struct.unpack_from('<H',pe,24)[0]
    if machine==0x8664 and magic!=0x20b:raise ValueError('inconsistent_pe_architecture')
    return {'architecture':{0x8664:'x86_64',0x14c:'x86',0xaa64:'arm64'}.get(machine,'unknown'),
            'is_dll':bool(struct.unpack_from('<H',pe,22)[0]&0x2000)}


def steam_authorized(environment):
    values=[environment[key]for key in ('SteamAppId','SteamGameId')if key in environment]
    return bool(values)and all(value=='322330'for value in values)


def find_java(environment=None):
    environment=os.environ if environment is None else environment
    candidates=[]
    if environment.get('JAVA_HOME'):candidates.append(Path(environment['JAVA_HOME'])/'bin'/('java.exe'if os.name=='nt'else'java'))
    if sys.platform=='darwin':
        result=subprocess.run(['/usr/libexec/java_home','-v','21'],capture_output=True,text=True)
        if result.returncode==0:candidates.append(Path(result.stdout.strip())/'bin/java')
    if shutil.which('java'):candidates.append(Path(shutil.which('java')))
    for java in candidates:
        if not java.is_file():continue
        result=subprocess.run([str(java),'-XshowSettings:properties','-version'],capture_output=True,text=True,timeout=15)
        properties={}
        for line in (result.stdout+result.stderr).splitlines():
            if '='in line:
                key,_,value=line.partition('=');properties[key.strip()]=value.strip()
        if result.returncode==0 and properties.get('java.specification.version')=='21':return java.resolve()
    raise ValueError('Java 21 required; set JAVA_HOME to an installed JDK 21')


def gradle_command(root,java,arguments):
    return [str(java),'-classpath',str(Path(root)/'mc/gradle/wrapper/gradle-wrapper.jar'),
            'org.gradle.wrapper.GradleWrapperMain','-p',str(Path(root)/'mc'),*arguments,'--console','plain']


def steam_option(root,platform=None):
    script=Path(root)/'tools/steam_dst.py'
    if (platform or platform_name())=='windows':
        # Steam interprets %command%; Python receives the resulting argv intact.
        return subprocess.list2cmdline([sys.executable,'-X','utf8','-B',str(script)])+' %command%'
    return '/usr/bin/arch -arm64 /usr/bin/python3 -B "'+str(script)+'" %command%'
