@IsTest
private class GeotabLocationSyncServiceTest {

  @IsTest
  static void parseDeviceStatusAndBuildCron() {
    Map<String, Object> row = new Map<String, Object>{
      'device' => new Map<String, Object>{ 'id' => 'b1' },
      'latitude' => 40.123,
      'longitude' => -74.456,
      'dateTime' => '2026-06-24T10:15:30.000Z'
    };

    GeotabLocationSyncService.DeviceStatusPayload payload =
      GeotabLocationSyncService.parseDeviceStatus(row);

    System.assertEquals('b1', payload.deviceId);
    System.assertEquals('40.123', payload.latitude);
    System.assertEquals('-74.456', payload.longitude);
    System.assertNotEquals(null, payload.gpsTime);
    System.assertEquals('0 0 * * * ?', GeotabLocationSyncScheduler.buildCron(30));
    System.assertEquals('0 0 * * * ?', GeotabLocationSyncScheduler.buildCron(60));
  }

  @IsTest
  static void syncLatestLocationsWithMockedApi() {
    GeotabApiService.testConfig = new Geotab_Integration_Config__mdt(
      Is_Enabled__c = true,
      Status__c = 'Active',
      Create_Location_History__c = false,
      Location_History_Interval_Minutes__c = 5
    );
    GeotabApiService.testSyncState = new Geotab_Sync_State__c();

    fax__Vehicle__c vehicle = new fax__Vehicle__c(
      Name = 'Truck 1',
      Geotab_Device_Id__c = 'b1'
    );
    insert vehicle;

    fax__Service_Engineer__c engineer = new fax__Service_Engineer__c(
      Name = 'Engineer One',
      fax__Active__c = 'Yes',
      fax__Enable_GPS_Tracking__c = true
    );
    insert engineer;

    insert new fax__Vehicle_Mapped__c(
      fax__Vehicle__c = vehicle.Id,
      fax__Service_Engineer__c = engineer.Id,
      fax__Status__c = 'Active',
      fax__Start__c = Date.today().addDays(-1)
    );

    Test.setMock(HttpCalloutMock.class, new GeotabApiMock());

    Test.startTest();
    GeotabLocationSyncService.SyncSummary summary = GeotabLocationSyncService.syncLatestLocations();
    Test.stopTest();

    System.assertEquals(1, summary.statusRecordsProcessed);
    System.assertEquals(1, summary.engineersUpdated);

    fax__Service_Engineer__c updated = [
      SELECT fax__Latitude__c, fax__Longitude__c
      FROM fax__Service_Engineer__c
      WHERE Id = :engineer.Id
    ];
    System.assertEquals('40.1', updated.fax__Latitude__c);
    System.assertEquals('-74.2', updated.fax__Longitude__c);
  }

  @IsTest
  static void syncCreatesLocationHistoryWhenEnabled() {
    GeotabApiService.testConfig = new Geotab_Integration_Config__mdt(
      Is_Enabled__c = true,
      Status__c = 'Active',
      Create_Location_History__c = true,
      Location_History_Interval_Minutes__c = 0
    );
    GeotabApiService.testSyncState = new Geotab_Sync_State__c();

    fax__Vehicle__c vehicle = new fax__Vehicle__c(Name = 'Truck 2', Geotab_Device_Id__c = 'b9');
    insert vehicle;
    fax__Service_Engineer__c engineer = new fax__Service_Engineer__c(
      Name = 'Engineer Two',
      fax__Active__c = 'Yes',
      fax__Enable_GPS_Tracking__c = true
    );
    insert engineer;
    insert new fax__Vehicle_Mapped__c(
      fax__Vehicle__c = vehicle.Id,
      fax__Service_Engineer__c = engineer.Id,
      fax__Status__c = 'Active',
      fax__Start__c = Date.today().addDays(-1)
    );

    Test.setMock(HttpCalloutMock.class, new GeotabApiMock('b9'));
    Test.startTest();
    GeotabLocationSyncService.SyncSummary summary = GeotabLocationSyncService.syncLatestLocations();
    Test.stopTest();

    System.assertEquals(1, summary.historyRecordsCreated);
  }

  private class GeotabApiMock implements HttpCalloutMock {
    private String deviceId;
    GeotabApiMock() {
      this.deviceId = 'b1';
    }
    GeotabApiMock(String deviceId) {
      this.deviceId = deviceId;
    }
    public HttpResponse respond(HttpRequest req) {
      HttpResponse res = new HttpResponse();
      res.setStatusCode(200);
      Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(req.getBody());
      String method = (String) body.get('method');
      if (method == 'Authenticate') {
        res.setBody(
          '{"result":{"credentials":{"sessionId":"session-123","database":"testdb","userName":"user@test.com"}}}'
        );
      } else {
        res.setBody(
          '{"result":{"data":[{"device":{"id":"' + deviceId + '"},"latitude":40.1,"longitude":-74.2,"dateTime":"2026-06-24T10:00:00.000Z"}],"toVersion":"v-next"}}'
        );
      }
      return res;
    }
  }
}