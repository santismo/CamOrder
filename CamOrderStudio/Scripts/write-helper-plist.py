import plistlib, sys
info = {
 'CFBundleIdentifier':'com.santismo.CamOrderStudio.Capture', 'CFBundleName':'CamOrder Capture',
 'CFBundleExecutable':'CamOrderCapture', 'CFBundlePackageType':'APPL', 'LSUIElement':True,
 'CFBundleShortVersionString':'0.4.0', 'CFBundleVersion':'400', 'LSMinimumSystemVersion':'13.0',
 'NSCameraUsageDescription':'Record video from the input you choose inside the CamOrder Studio plug-in.',
 'NSScreenCaptureUsageDescription':'Record the screen or region you choose inside the CamOrder Studio plug-in.',
 'NSCameraUseContinuityCameraDeviceType':True,
}
with open(sys.argv[1],'wb') as f: plistlib.dump(info,f)
