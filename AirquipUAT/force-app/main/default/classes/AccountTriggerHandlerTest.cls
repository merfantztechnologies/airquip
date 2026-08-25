@IsTest
private class AccountTriggerHandlerTest {

    private static Account buildTestAccount(String name) {
        return buildTestAccount(name, null);
    }

    private static Account buildTestAccount(String name, String phone) {
        Account acc = new Account(
            Name = name,
            BillingStreet = '123 Main St',
            BillingCity = 'Houston',
            BillingState = 'Texas',
            BillingPostalCode = '77001',
            BillingCountry = 'United States',
            ShippingStreet = '456 Ship Ave',
            ShippingCity = 'Dallas',
            ShippingState = 'Texas',
            ShippingPostalCode = '75001',
            ShippingCountry = 'United States'
        );
        if (phone != null) {
            acc.Phone = phone;
        }
        return acc;
    }

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
                faxa__FieldAx_Field__c = 'Website',
                faxa__External_App_Field__c = 'WebAddr.URI',
                faxa__External_App__c = app.Id,
                faxa__Sequence__c = 3
            )
        };
        insert mappings;
    }

    @IsTest
    static void testSyncFlagSetOnMappedFieldChange() {
        Account acc = buildTestAccount('Test Corp', '555-1234');
        insert acc;

        acc.Phone = '555-9999';

        Test.startTest();
        update acc;
        Test.stopTest();

        Account result = [
            SELECT faxa__Sync_to_QuickBooks__c FROM Account WHERE Id = :acc.Id
        ];
        System.assertEquals(true, result.faxa__Sync_to_QuickBooks__c,
            'Sync flag should be true when a mapped field changes');
    }

    @IsTest
    static void testSyncFlagNotSetWhenNoMappedFieldChanges() {
        Account acc = buildTestAccount('Test Corp', '555-1234');
        acc.Description = 'Old';
        insert acc;

        update new Account(Id = acc.Id, faxa__Sync_to_QuickBooks__c = false);

        acc.Description = 'Updated description';

        Test.startTest();
        update acc;
        Test.stopTest();

        Account result = [
            SELECT faxa__Sync_to_QuickBooks__c FROM Account WHERE Id = :acc.Id
        ];
        System.assertEquals(false, result.faxa__Sync_to_QuickBooks__c,
            'Sync flag should remain false when only unmapped fields change');
    }

    @IsTest
    static void testSyncFlagSetOnNameChange() {
        Account acc = buildTestAccount('Original Name');
        insert acc;

        acc.Name = 'Updated Name';

        Test.startTest();
        update acc;
        Test.stopTest();

        Account result = [
            SELECT faxa__Sync_to_QuickBooks__c FROM Account WHERE Id = :acc.Id
        ];
        System.assertEquals(true, result.faxa__Sync_to_QuickBooks__c,
            'Sync flag should be true when Name changes');
    }

    @IsTest
    static void testNoMappingsNoSync() {
        delete [SELECT Id FROM faxa__Mapping__c];

        Account acc = buildTestAccount('Test Corp', '555-1234');
        insert acc;

        update new Account(Id = acc.Id, faxa__Sync_to_QuickBooks__c = false);

        acc.Phone = '555-0000';

        Test.startTest();
        update acc;
        Test.stopTest();

        Account result = [
            SELECT faxa__Sync_to_QuickBooks__c FROM Account WHERE Id = :acc.Id
        ];
        System.assertEquals(false, result.faxa__Sync_to_QuickBooks__c,
            'Sync flag should remain false when no mappings exist');
    }

    @IsTest
    static void testSyncFlagSetOnInsert() {
        Test.startTest();
        Account acc = buildTestAccount('New Account', '555-1234');
        insert acc;
        Test.stopTest();

        Account result = [
            SELECT faxa__Sync_to_QuickBooks__c FROM Account WHERE Id = :acc.Id
        ];
        System.assertEquals(true, result.faxa__Sync_to_QuickBooks__c,
            'Sync flag should be true on insert');
    }

    @IsTest
    static void testBulkInsert() {
        List<Account> accounts = new List<Account>();
        for (Integer i = 0; i < 200; i++) {
            accounts.add(buildTestAccount('Bulk Insert Account ' + i));
        }

        Test.startTest();
        insert accounts;
        Test.stopTest();

        List<Account> results = [
            SELECT faxa__Sync_to_QuickBooks__c FROM Account
            WHERE Id IN :accounts AND faxa__Sync_to_QuickBooks__c = true
        ];
        System.assertEquals(200, results.size(),
            'All 200 inserted accounts should have sync flag set to true');
    }

    @IsTest
    static void testBulkUpdate() {
        List<Account> accounts = new List<Account>();
        for (Integer i = 0; i < 200; i++) {
            accounts.add(buildTestAccount('Bulk Account ' + i, '555-0000'));
        }
        insert accounts;

        for (Account acc : accounts) {
            acc.Phone = '555-1111';
        }

        Test.startTest();
        update accounts;
        Test.stopTest();

        List<Account> results = [
            SELECT faxa__Sync_to_QuickBooks__c FROM Account
            WHERE Id IN :accounts AND faxa__Sync_to_QuickBooks__c = true
        ];
        System.assertEquals(200, results.size(),
            'All 200 accounts should have sync flag set to true');
    }
}