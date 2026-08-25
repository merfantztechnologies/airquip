@IsTest
private class GeotabIntegrationControllerTest {

  private static Geotab_Integration_Config__mdt inactiveConfig() {
    return new Geotab_Integration_Config__mdt(
      Is_Enabled__c = false,
      Status__c = 'Inactive'
    );
  }

  @IsTest
  static void queueableSkipsWhenIntegrationInactive() {
    GeotabApiService.testConfig = inactiveConfig();
    Test.startTest();
    System.enqueueJob(new GeotabLocationSyncQueueable());
    Test.stopTest();
    System.assertEquals(null, GeotabApiService.getSyncState().Last_Sync_Status__c);
  }

  @IsTest
  static void schedulerSkipsWhenIntegrationInactive() {
    GeotabApiService.testConfig = inactiveConfig();
    Test.startTest();
    new GeotabLocationSyncScheduler().execute(null);
    Test.stopTest();
    System.assertEquals(0, [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name = :GeotabLocationSyncScheduler.JOB_NAME]);
  }

  @IsTest
  static void controllerFailsWhenIntegrationInactive() {
    GeotabApiService.testConfig = inactiveConfig();
    Boolean threw = false;
    try {
      GeotabIntegrationController.runLocationSyncNow();
    } catch (AuraHandledException ex) {
      threw = true;
    }
    System.assertEquals(true, threw);
  }

  @IsTest
  static void controllerOperations() {
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
    Test.setMock(HttpCalloutMock.class, new GeotabApiMock());

    Test.startTest();
    GeotabIntegrationController.ConnectionResult connection = GeotabIntegrationController.testConnection();
    GeotabIntegrationController.SyncStateResult state = GeotabIntegrationController.getSyncState();
    String locationMsg = GeotabIntegrationController.runLocationSyncNow();
    String deviceMsg = GeotabIntegrationController.runDeviceSyncNow();
    String scheduleMsg = GeotabIntegrationController.scheduleLocationSync();
    String stopMsg = GeotabIntegrationController.stopLocationSync();
    GeotabDeviceSyncScheduler.testCronExpression = '0 15 * * * ?';
    String deviceScheduleMsg = GeotabIntegrationController.scheduleDeviceSync();
    String deviceStopMsg = GeotabIntegrationController.stopDeviceSync();
    Test.stopTest();
    GeotabLocationSyncScheduler.testCronExpression = null;
    GeotabDeviceSyncScheduler.testCronExpression = null;

    System.assertEquals(true, connection.success);
    System.assertEquals(true, state.integrationActive);
    System.assert(locationMsg.contains('queued'));
    System.assert(deviceMsg.contains('batch'));
    System.assert(scheduleMsg.contains('scheduler'));
    System.assert(stopMsg.contains('stopped'));
    System.assert(deviceScheduleMsg.contains('hour'));
    System.assert(deviceStopMsg.contains('stopped'));
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