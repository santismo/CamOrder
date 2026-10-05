import plistlib, sys
info = {
 'CFBundleIdentifier':'com.santismo.CamOrderStudio.AudioUnit', 'CFBundleName':'CamOrder Studio',
 'CFBundleExecutable':'CamOrderStudioAU', 'CFBundlePackageType':'BNDL',
 'CFBundleShortVersionString':'0.7.0', 'CFBundleVersion':'700', 'LSMinimumSystemVersion':'13.0',
 'NSCameraUsageDescription':'CamOrder Studio records video from your chosen camera.',
 'NSScreenCaptureUsageDescription':'CamOrder Studio records your selected screen region.',
 'NSCameraUseContinuityCameraDeviceType':True,
 'AudioComponents':[{'name':'Santismo: CamOrder Studio','description':'Video capture, editing and movie export for Logic Pro',
 'manufacturer':'Sntm','subtype':'CmSt','type':'aufx','version':0x00000700,
 'factoryFunction':'CamOrderStudioAUFactory','sandboxSafe':False,
 'resourceUsage':{'network.client':False, 'temporary-exception.files.all.read-write':True},
 'tags':['Video','Utility']}]
}
with open(sys.argv[1],'wb') as f: plistlib.dump(info,f)
