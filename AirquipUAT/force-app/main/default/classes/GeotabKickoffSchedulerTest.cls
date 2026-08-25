@IsTest
private class GeotabKickoffSchedulerTest {

  @IsTest
  static void kickoffRunsWhenIntegrationActive() {
    GeotabApiService.testConfig = new Geotab_Integration_Config__mdt(
      Is_Enabled__c = true,
      Status__c = 'Active',
      Device_Sync_Enabled__c = true,
      Device_Sync_Batch_Size__c = 10,
      Sync_Interval_Seconds__c = 60,
      Create_Location_History__c = false
    );
    GeotabApiService.testSyncState = new Geotab_Sync_State__c();
    GeotabLocationSyncScheduler.testCronExpression = '0 15 * * * ?';
    GeotabDeviceSyncScheduler.testCronExpression = '0 15 * * * ?';
    Test.setMock(HttpCalloutMock.class, new GeotabApiMock());

    Test.startTest();
    new GeotabKickoffScheduler().execute(null);
    Test.stopTest();
    GeotabDeviceSyncScheduler.testCronExpression = null;

    System.assertEquals(2, [SELECT COUNT() FROM AsyncApexJob WHERE JobType = 'BatchApex']);
  }

  @IsTest
  static void kickoffSkipsWhenIntegrationInactive() {
    GeotabApiService.testConfig = new Geotab_Integration_Config__mdt(
      Is_Enabled__c = false,
      Status__c = 'Inactive'
    );
    Test.startTest();
    new GeotabKickoffScheduler().execute(null);
    Test.stopTest();
    System.assertEquals(0, [SELECT COUNT() FROM AsyncApexJob WHERE JobType = 'BatchApex']);
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