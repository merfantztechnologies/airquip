@IsTest
private class GeotabLocationSyncQueueableTest {

  @IsTest
  static void doesNotChainWhenIntervalIsSixtySeconds() {
    GeotabApiService.testConfig = new Geotab_Integration_Config__mdt(
      Is_Enabled__c = true,
      Status__c = 'Active',
      Sync_Interval_Seconds__c = 60,
      Create_Location_History__c = false
    );
    GeotabApiService.testSyncState = new Geotab_Sync_State__c();
    Test.setMock(HttpCalloutMock.class, new GeotabApiMock());

    Test.startTest();
    System.enqueueJob(new GeotabLocationSyncQueueable(true));
    Test.stopTest();

    System.assertEquals('Success', GeotabApiService.getSyncState().Last_Sync_Status__c);
  }

  @IsTest
  static void executesWhenIntegrationActive() {
    GeotabApiService.testConfig = new Geotab_Integration_Config__mdt(
      Is_Enabled__c = true,
      Status__c = 'Active',
      Create_Location_History__c = false
    );
    GeotabApiService.testSyncState = new Geotab_Sync_State__c();
    Test.setMock(HttpCalloutMock.class, new GeotabApiMock());

    Test.startTest();
    System.enqueueJob(new GeotabLocationSyncQueueable());
    Test.stopTest();

    System.assertEquals('Success', GeotabApiService.getSyncState().Last_Sync_Status__c);
  }

  @IsTest
  static void queueableRecordsErrorOnFailure() {
    GeotabApiService.testConfig = new Geotab_Integration_Config__mdt(
      Is_Enabled__c = true,
      Status__c = 'Active'
    );
    GeotabApiService.testSyncState = new Geotab_Sync_State__c();
    Test.setMock(HttpCalloutMock.class, new GeotabErrorMock());

    Test.startTest();
    System.enqueueJob(new GeotabLocationSyncQueueable());
    Test.stopTest();

    System.assertEquals('Error', GeotabApiService.getSyncState().Last_Sync_Status__c);
  }

  private class GeotabErrorMock implements HttpCalloutMock {
    public HttpResponse respond(HttpRequest req) {
      HttpResponse res = new HttpResponse();
      res.setStatusCode(500);
      res.setBody('error');
      return res;
    }
  }

  private class GeotabApiMock implements HttpCalloutMock {
    public HttpResponse respond(HttpRequest req) {
      HttpResponse res = new HttpResponse();
      res.setStatusCode(200);
      Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(req.getBody());
      if (body.get('method') == 'Authenticate') {
        res.setBody(
          '{"result":{"credentials":{"sessionId":"session-123","database":"testdb","userName":"user@test.com"}}}'
        );
      } else {
        res.setBody('{"result":{"data":[],"toVersion":"v-next"}}');
      }
      return res;
    }
  }
}