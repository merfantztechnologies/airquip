@IsTest
private class GeotabApiServiceTest {

  @IsTest
  static void getActiveConfigRespectsInactiveTestInjection() {
    GeotabApiService.testConfig = new Geotab_Integration_Config__mdt(
      Is_Enabled__c = false,
      Status__c = 'Inactive'
    );
    System.assertEquals(false, GeotabApiService.isIntegrationActive());
  }

  @IsTest
  static void authenticateAndGetFeed() {
    GeotabApiService.testConfig = new Geotab_Integration_Config__mdt(
      Is_Enabled__c = true,
      Status__c = 'Active'
    );
    GeotabApiService.testSyncState = new Geotab_Sync_State__c();

    Test.setMock(HttpCalloutMock.class, new GeotabApiMock());

    Test.startTest();
    GeotabApiService.SessionCredentials session = GeotabApiService.authenticate();
    GeotabApiService.FeedResult feed = GeotabApiService.getFeed('DeviceStatusInfo', '0');
    Test.stopTest();

    System.assertEquals('session-123', session.sessionId);
    System.assertEquals(1, feed.data.size());
    System.assertNotEquals(null, feed.toVersion);
  }

  @IsTest
  static void getActiveConfigUsesTestInjection() {
    GeotabApiService.testConfig = new Geotab_Integration_Config__mdt(
      Is_Enabled__c = true,
      Status__c = 'Active'
    );
    System.assertEquals(true, GeotabApiService.isIntegrationActive());
  }

  @IsTest
  static void getActiveConfigDeveloperNameUsesSyncState() {
    GeotabApiService.testSyncState = new Geotab_Sync_State__c(
      Active_Config_Developer_Name__c = 'UAT'
    );
    System.assertEquals('UAT', GeotabApiService.getActiveConfigDeveloperName());
  }

  @IsTest
  static void getActiveConfigDeveloperNameDefaultsToDefault() {
    GeotabApiService.testSyncState = new Geotab_Sync_State__c();
    System.assertEquals(GeotabApiService.CONFIG_RECORD, GeotabApiService.getActiveConfigDeveloperName());
  }

  @IsTest(SeeAllData=true)
  static void getConfigQueriesMetadataByDeveloperName() {
    GeotabApiService.testConfig = null;
    GeotabApiService.testConfigDeveloperName = 'Default';
    GeotabApiService.testSyncState = new Geotab_Sync_State__c(
      Active_Config_Developer_Name__c = 'Default'
    );
    Geotab_Integration_Config__mdt config = GeotabApiService.getConfig();
    System.assertNotEquals(null, config);
    System.assertEquals('Default', config.DeveloperName);
  }

  @IsTest
  static void getFeedCachesNewSessionAfterCallout() {
    GeotabApiService.testConfig = new Geotab_Integration_Config__mdt(
      Is_Enabled__c = true,
      Status__c = 'Active'
    );
    GeotabApiService.testSyncState = new Geotab_Sync_State__c();
    Test.setMock(HttpCalloutMock.class, new GeotabApiMock());

    Test.startTest();
    GeotabApiService.FeedResult feed = GeotabApiService.getFeed('DeviceStatusInfo', '0');
    Test.stopTest();

    System.assertEquals(1, feed.data.size());
    System.assertEquals('session-123', GeotabApiService.getSyncState().Session_Id__c);
    System.assertNotEquals(null, GeotabApiService.getSyncState().Session_Expires_At__c);
  }

  private class GeotabApiMock implements HttpCalloutMock {
    public HttpResponse respond(HttpRequest req) {
      HttpResponse res = new HttpResponse();
      res.setStatusCode(200);
      Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(req.getBody());
      String method = (String) body.get('method');

      if (method == 'Authenticate') {
        res.setBody(
          '{"result":{"credentials":{"sessionId":"session-123","database":"testdb","userName":"user@test.com"}}}'
        );
        return res;
      }
      if (method == 'GetFeed') {
        res.setBody(
          '{"result":{"data":[{"device":{"id":"b1"},"latitude":40.1,"longitude":-74.2,"dateTime":"2026-06-24T10:00:00.000Z"}],"toVersion":"v-next"}}'
        );
        return res;
      }
      res.setBody('{"error":{"message":"Unknown method"}}');
      return res;
    }
  }
}