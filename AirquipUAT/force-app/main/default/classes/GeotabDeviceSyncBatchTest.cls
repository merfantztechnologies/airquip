@IsTest
private class GeotabDeviceSyncBatchTest {

  @IsTest
  static void upsertsVehiclesFromDeviceFeed() {
    GeotabApiService.testConfig = new Geotab_Integration_Config__mdt(
      Is_Enabled__c = true,
      Status__c = 'Active',
      Device_Sync_Enabled__c = true,
      Device_Sync_Batch_Size__c = 10
    );
    GeotabApiService.testSyncState = new Geotab_Sync_State__c();

    Test.setMock(HttpCalloutMock.class, new GeotabApiMock());

    Test.startTest();
    Database.executeBatch(new GeotabDeviceSyncBatch(), 10);
    Test.stopTest();

    List<fax__Vehicle__c> vehicles = [
      SELECT Geotab_Device_Id__c, Geotab_Serial_Number__c, Name
      FROM fax__Vehicle__c
      WHERE Geotab_Device_Id__c = 'b1'
    ];
    System.assertEquals(1, vehicles.size());
    System.assertEquals('SN-001', vehicles[0].Geotab_Serial_Number__c);
  }

  @IsTest
  static void mapDeviceToVehicleHandlesMissingName() {
    Map<String, Object> device = new Map<String, Object>{
      'id' => 'b2',
      'serialNumber' => 'SN-002'
    };
    fax__Vehicle__c vehicle = GeotabDeviceSyncBatch.mapDeviceToVehicle(device, System.now());
    System.assertEquals('SN-002', vehicle.Name);
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
      } else {
        res.setBody(
          '{"result":{"data":[{"id":"b1","name":"Fleet Truck","serialNumber":"SN-001","vehicleIdentificationNumber":"VIN123"}],"toVersion":"v-next"}}'
        );
      }
      return res;
    }
  }
}