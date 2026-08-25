@IsTest
private class QuickBooksMapperServiceTest {

    @TestSetup
    static void setup() {
        faxa__External_App__c app = new faxa__External_App__c(
            Name = 'QuickBook',
            faxa__Realm_ID__c = '1234567890',
            faxa__Access_Token__c = 'mock_token',
            faxa__Refresh_Token__c = 'mock_refresh',
            faxa__Client_Id__c = 'mock_client',
            faxa__Client_Secret__c = 'mock_secret',
            faxa__Authentication_Status__c = 'Successful'
        );
        insert app;

        List<faxa__Mapping__c> mappings = new List<faxa__Mapping__c>{
            new faxa__Mapping__c(
                faxa__FieldAx_Object__c = 'Account',
                faxa__FieldAx_Field__c = 'Name',
                faxa__External_App_Field__c = 'DisplayName',
                faxa__External_App__c = app.Id,
                faxa__Sequence__c = 1
            ),
            new faxa__Mapping__c(
                faxa__FieldAx_Object__c = 'Account',
                faxa__FieldAx_Field__c = 'Phone',
                faxa__External_App_Field__c = 'PrimaryPhone.FreeFormNumber',
                faxa__External_App__c = app.Id,
                faxa__Sequence__c = 2
            ),
            new faxa__Mapping__c(
                faxa__FieldAx_Object__c = 'Account',
                faxa__FieldAx_Field__c = 'BillingStreet',
                faxa__External_App_Field__c = 'BillAddr.Line1',
                faxa__External_App__c = app.Id,
                faxa__Sequence__c = 3
            ),
            new faxa__Mapping__c(
                faxa__FieldAx_Object__c = 'Account',
                faxa__FieldAx_Field__c = 'BillingCity',
                faxa__External_App_Field__c = 'BillAddr.City',
                faxa__External_App__c = app.Id,
                faxa__Sequence__c = 4
            ),
            new faxa__Mapping__c(
                faxa__FieldAx_Object__c = 'Account',
                faxa__FieldAx_Field__c = 'Website',
                faxa__External_App_Field__c = 'WebAddr.URI',
                faxa__External_App__c = app.Id,
                faxa__Sequence__c = 5
            ),
            new faxa__Mapping__c(
                faxa__FieldAx_Object__c = 'Account',
                faxa__FieldAx_Field__c = 'faxa__QuickBooks_Customer_Id__c',
                faxa__External_App_Field__c = 'QuickBooksCustomerId',
                faxa__External_App__c = app.Id,
                faxa__Sequence__c = 6
            )
        };
        insert mappings;

        Account acc = new Account(
            Name = 'Test Corp',
            Phone = '555-1234',
            BillingStreet = '123 Main St',
            BillingCity = 'Houston',
            Website = 'https://testcorp.com',
            faxa__QuickBooks_Customer_Id__c = '101'
        );
        insert acc;
    }

    private static faxa__External_App__c getApp() {
        return [SELECT Id FROM faxa__External_App__c WHERE Name = 'QuickBook' LIMIT 1];
    }

    private static Account getAccount() {
        return [SELECT Id FROM Account WHERE Name = 'Test Corp' LIMIT 1];
    }

    @IsTest
    static void testBuildPayloadCreate() {
        faxa__External_App__c app = getApp();
        Account acc = getAccount();

        Test.startTest();
        String payload = QuickBooksMapperService.buildPayload(
            'Account', acc.Id, app.Id, 'CREATE'
        );
        Test.stopTest();

        System.assertNotEquals(null, payload, 'Payload should not be null');
        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(payload);

        System.assertEquals('Test Corp', parsed.get('DisplayName'));
        System.assert(!parsed.containsKey('Id'), 'CREATE should not include QB Id');

        Map<String, Object> phone = (Map<String, Object>) parsed.get('PrimaryPhone');
        System.assertNotEquals(null, phone, 'PrimaryPhone should be nested');
        System.assertEquals('555-1234', phone.get('FreeFormNumber'));

        Map<String, Object> billAddr = (Map<String, Object>) parsed.get('BillAddr');
        System.assertEquals('123 Main St', billAddr.get('Line1'));
        System.assertEquals('Houston', billAddr.get('City'));

        Map<String, Object> webAddr = (Map<String, Object>) parsed.get('WebAddr');
        System.assertEquals('https://testcorp.com', webAddr.get('URI'));
    }

    @IsTest
    static void testBuildPayloadUpdate() {
        faxa__External_App__c app = getApp();
        Account acc = getAccount();

        Test.startTest();
        String payload = QuickBooksMapperService.buildPayload(
            'Account', acc.Id, app.Id, 'UPDATE'
        );
        Test.stopTest();

        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(payload);
        System.assertEquals('101', parsed.get('Id'), 'UPDATE should include QB Id');
        System.assertEquals('Test Corp', parsed.get('DisplayName'));
    }

    @IsTest
    static void testBuildPayloadUpdateNoQbId() {
        faxa__External_App__c app = getApp();

        Account acc = new Account(Name = 'No QB Id Corp');
        insert acc;

        Test.startTest();
        String payload = QuickBooksMapperService.buildPayload(
            'Account', acc.Id, app.Id, 'UPDATE'
        );
        Test.stopTest();

        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(payload);
        System.assert(!parsed.containsKey('Id'), 'Should not include Id when QB Id is null');
    }

    @IsTest
    static void testBuildPayloadNullFields() {
        faxa__External_App__c app = getApp();

        Account acc = new Account(Name = 'Minimal Corp');
        insert acc;

        Test.startTest();
        String payload = QuickBooksMapperService.buildPayload(
            'Account', acc.Id, app.Id, 'CREATE'
        );
        Test.stopTest();

        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(payload);
        System.assertEquals('Minimal Corp', parsed.get('DisplayName'));
        System.assert(!parsed.containsKey('PrimaryPhone'), 'Null phone should not appear in payload');
        System.assert(!parsed.containsKey('WebAddr'), 'Null website should not appear in payload');
    }

    @IsTest
    static void testBuildPayloadDefaultValue() {
        faxa__External_App__c app = getApp();

        faxa__Mapping__c defaultMapping = new faxa__Mapping__c(
            faxa__FieldAx_Object__c = 'Account',
            faxa__External_App_Field__c = 'CompanyName',
            faxa__External_App__c = app.Id,
            faxa__Default_Value__c = 'Default Company',
            faxa__Sequence__c = 10
        );
        insert defaultMapping;

        Account acc = getAccount();

        Test.startTest();
        String payload = QuickBooksMapperService.buildPayload(
            'Account', acc.Id, app.Id, 'CREATE'
        );
        Test.stopTest();

        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(payload);
        System.assertEquals('Default Company', parsed.get('CompanyName'),
            'Should use default value when no source field is specified');
    }

    @IsTest
    static void testNoMappingsThrowsException() {
        faxa__External_App__c app = getApp();

        faxa__External_App__c otherApp = new faxa__External_App__c(
            Name = 'OtherApp',
            faxa__Realm_ID__c = '9999999999',
            faxa__Access_Token__c = 'x',
            faxa__Refresh_Token__c = 'x',
            faxa__Client_Id__c = 'x',
            faxa__Client_Secret__c = 'x',
            faxa__Authentication_Status__c = 'Successful'
        );
        insert otherApp;

        Account acc = getAccount();

        Test.startTest();
        try {
            QuickBooksMapperService.buildPayload(
                'Account', acc.Id, otherApp.Id, 'CREATE'
            );
            System.assert(false, 'Should have thrown QuickBooksMapperException');
        } catch (QuickBooksMapperService.QuickBooksMapperException e) {
            System.assert(e.getMessage().contains('No mappings found'),
                'Exception should mention missing mappings');
        }
        Test.stopTest();
    }

    @IsTest
    static void testGetParentMappingsForFieldAxObject() {
        faxa__External_App__c app = getApp();

        Test.startTest();
        List<faxa__Mapping__c> mappings =
            QuickBooksMapperService.getParentMappingsForFieldAxObject('Account', app.Id);
        Test.stopTest();

        System.assertEquals(6, mappings.size(), 'Should return all 6 Account mappings');
        System.assertEquals(1, mappings[0].faxa__Sequence__c, 'Should be ordered by sequence');
    }

    @IsTest
    static void testDeepNestedPayload() {
        faxa__External_App__c app = getApp();

        faxa__Mapping__c deepMapping = new faxa__Mapping__c(
            faxa__FieldAx_Object__c = 'Account',
            faxa__FieldAx_Field__c = 'Name',
            faxa__External_App_Field__c = 'MetaData.Level1.Level2',
            faxa__External_App__c = app.Id,
            faxa__Sequence__c = 20
        );
        insert deepMapping;

        Account acc = getAccount();

        Test.startTest();
        String payload = QuickBooksMapperService.buildPayload(
            'Account', acc.Id, app.Id, 'CREATE'
        );
        Test.stopTest();

        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(payload);
        Map<String, Object> meta = (Map<String, Object>) parsed.get('MetaData');
        System.assertNotEquals(null, meta, 'MetaData should exist');
        Map<String, Object> level1 = (Map<String, Object>) meta.get('Level1');
        System.assertNotEquals(null, level1, 'Level1 should exist');
        System.assertEquals('Test Corp', level1.get('Level2'), 'Deep nested value should be set');
    }
}