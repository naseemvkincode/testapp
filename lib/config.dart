class UpdateConfig {
  static const String metadataFileId = 'YOUR_METADATA_JSON_FILE_ID';
  static const String installerFileId = 'YOUR_INSTALLER_FILE_ID';

  static const String googleDriveBaseUrl =
      'https://drive.google.com/uc?export=download&id=';

  static String get metadataUrl => '$googleDriveBaseUrl$metadataFileId';

  static String getInstallerUrl(String fileId) =>
      '$googleDriveBaseUrl$fileId';

  static const String appName = 'TestApp';
  static const String tempDownloadFolder = 'TestApp-Update';
}
