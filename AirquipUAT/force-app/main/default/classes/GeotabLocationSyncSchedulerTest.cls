@IsTest
private class GeotabLocationSyncSchedulerTest {

  @IsTest
  static void buildScheduleDefinitionsUsesMetadataCadence() {
    List<GeotabLocationSyncScheduler.ScheduleDefinition> oneMinuteSchedules =
      GeotabLocationSyncScheduler.buildScheduleDefinitions(60);
    System.assertEquals(60, oneMinuteSchedules.size());
    System.assertEquals('Geotab Location Sync 00', oneMinuteSchedules[0].jobName);
    System.assertEquals('0 0 * * * ?', oneMinuteSchedules[0].cronExpression);
    System.assertEquals('Geotab Location Sync 59', oneMinuteSchedules[59].jobName);
    System.assertEquals('0 59 * * * ?', oneMinuteSchedules[59].cronExpression);

    List<GeotabLocationSyncScheduler.ScheduleDefinition> fiveMinuteSchedules =
      GeotabLocationSyncScheduler.buildScheduleDefinitions(300);
    System.assertEquals(12, fiveMinuteSchedules.size());
    System.assertEquals('0 5 * * * ?', fiveMinuteSchedules[1].cronExpression);

    List<GeotabLocationSyncScheduler.ScheduleDefinition> hourlySchedules =
      GeotabLocationSyncScheduler.buildScheduleDefinitions(3600);
    System.assertEquals(1, hourlySchedules.size());
    System.assertEquals(GeotabLocationSyncScheduler.JOB_NAME, hourlySchedules[0].jobName);
    System.assertEquals('0 0 * * * ?', hourlySchedules[0].cronExpression);
  }

  @IsTest
  static void abortExistingJobsRemovesScheduledJob() {
    GeotabApiService.testConfig = new Geotab_Integration_Config__mdt(
      Is_Enabled__c = true,
      Status__c = 'Active',
      Sync_Interval_Seconds__c = 60
    );
    GeotabLocationSyncScheduler.testCronExpression = '0 15 * * * ?';
    System.schedule(
      GeotabLocationSyncScheduler.JOB_NAME,
      GeotabLocationSyncScheduler.testCronExpression,
      new GeotabLocationSyncScheduler()
    );
    System.schedule(
      GeotabLocationSyncScheduler.JOB_NAME + ' 00',
      '0 0 * * * ?',
      new GeotabLocationSyncScheduler()
    );
    Test.startTest();
    GeotabLocationSyncScheduler.abortExistingJobs();
    Test.stopTest();
    System.assertEquals(0, [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name LIKE 'Geotab Location Sync%']);
  }

  @IsTest
  static void schedulesAndExecutesQueueable() {
    GeotabApiService.testConfig = new Geotab_Integration_Config__mdt(
      Is_Enabled__c = true,
      Status__c = 'Active',
      Sync_Interval_Seconds__c = 60,
      Create_Location_History__c = false
    );
    GeotabApiService.testSyncState = new Geotab_Sync_State__c();
    Test.setMock(HttpCalloutMock.class, new GeotabApiMock());

    GeotabLocationSyncScheduler.testCronExpression = '0 15 * * * ?';
    Test.startTest();
    GeotabLocationSyncScheduler.scheduleFromConfig();
    new GeotabLocationSyncScheduler().execute(null);
    Test.stopTest();
    GeotabLocationSyncScheduler.testCronExpression = null;

    List<CronTrigger> jobs = [
      SELECT Id
      FROM CronTrigger
      WHERE CronJobDetail.Name = :GeotabLocationSyncScheduler.JOB_NAME
    ];
    System.assertEquals(1, jobs.size());
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