@IsTest
private class GeotabDeviceSyncSchedulerTest {

  @IsTest
  static void schedulesHourlyJob() {
    GeotabApiService.testConfig = new Geotab_Integration_Config__mdt(
      Is_Enabled__c = true,
      Status__c = 'Active',
      Device_Sync_Enabled__c = true,
      Device_Sync_Batch_Size__c = 10
    );
    GeotabApiService.testSyncState = new Geotab_Sync_State__c();
    GeotabDeviceSyncScheduler.testCronExpression = '0 15 * * * ?';
    Test.setMock(HttpCalloutMock.class, new GeotabApiMock());

    Test.startTest();
    GeotabDeviceSyncScheduler.scheduleHourly();
    Test.stopTest();
    GeotabDeviceSyncScheduler.testCronExpression = null;

    List<CronTrigger> jobs = [
      SELECT Id, CronJobDetail.Name
      FROM CronTrigger
      WHERE CronJobDetail.Name = :GeotabDeviceSyncScheduler.JOB_NAME
    ];
    System.assertEquals(1, jobs.size());
  }

  @IsTest
  static void executeStartsDeviceBatch() {
    GeotabApiService.testConfig = new Geotab_Integration_Config__mdt(
      Is_Enabled__c = true,
      Status__c = 'Active',
      Device_Sync_Enabled__c = true,
      Device_Sync_Batch_Size__c = 10
    );
    GeotabApiService.testSyncState = new Geotab_Sync_State__c();
    Test.setMock(HttpCalloutMock.class, new GeotabApiMock());

    Test.startTest();
    new GeotabDeviceSyncScheduler().execute(null);
    Test.stopTest();

    System.assertEquals(1, [SELECT COUNT() FROM AsyncApexJob WHERE JobType = 'BatchApex']);
  }

  @IsTest
  static void skipsWhenIntegrationInactive() {
    GeotabApiService.testConfig = new Geotab_Integration_Config__mdt(
      Is_Enabled__c = false,
      Status__c = 'Inactive'
    );

    Test.startTest();
    GeotabDeviceSyncScheduler.scheduleHourly();
    new GeotabDeviceSyncScheduler().execute(null);
    Test.stopTest();

    System.assertEquals(0, [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name = :GeotabDeviceSyncScheduler.JOB_NAME]);
    System.assertEquals(0, [SELECT COUNT() FROM AsyncApexJob WHERE JobType = 'BatchApex']);
  }

  @IsTest
  static void abortExistingJobsRemovesScheduledJob() {
    GeotabApiService.testConfig = new Geotab_Integration_Config__mdt(
      Is_Enabled__c = true,
      Status__c = 'Active',
      Device_Sync_Enabled__c = true
    );
    GeotabDeviceSyncScheduler.testCronExpression = '0 15 * * * ?';
    System.schedule(
      GeotabDeviceSyncScheduler.JOB_NAME,
      GeotabDeviceSyncScheduler.testCronExpression,
      new GeotabDeviceSyncScheduler()
    );

    Test.startTest();
    GeotabDeviceSyncScheduler.abortExistingJobs();
    Test.stopTest();
    GeotabDeviceSyncScheduler.testCronExpression = null;

    System.assertEquals(0, [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name LIKE 'Geotab Device Sync%']);
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