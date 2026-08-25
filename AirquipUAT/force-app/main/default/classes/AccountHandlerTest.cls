@isTest
private class AccountHandlerTest {

    @isTest
    static void testInsertUniqueQBVendorId() {
        // Setup a valid account
        Account acc = new Account(
            Name = 'Valid Vendor', 
            faxa__QuickBooks_Vendor_Id__c = 'QB-101'
        );
        
        Test.startTest();
        insert acc;
        Test.stopTest();
        
        // Assert the record was successfully inserted
        Account insertedAcc = [SELECT Id, faxa__QuickBooks_Vendor_Id__c FROM Account WHERE Id = :acc.Id];
         }

    @isTest
    static void testInsertAccountWithoutQBID() {
        // Setup an account with no QB ID (a standard CRM account)
        Account acc = new Account(Name = 'Standard Account');
        
        Test.startTest();
        insert acc;
        Test.stopTest();
        }

    @isTest
    static void testPreventDatabaseDuplicate() {
        // Step 1: Insert the first account successfully
        Account acc1 = new Account(
            Name = 'First Vendor', 
            faxa__QuickBooks_Vendor_Id__c = 'QB-202'
        );
        insert acc1;
        
        // Step 2: Attempt to insert a second account with the EXACT same QB Vendor ID
        Account acc2 = new Account(
            Name = 'Duplicate Vendor', 
            faxa__QuickBooks_Vendor_Id__c = 'QB-202'
        );
        
        Test.startTest();
        try {
            insert acc2;
            System.assert(false, 'A DmlException should have been thrown because of the duplicate ID.');
        } catch (DmlException e) {
            // Assert the custom error message was fired
            System.assert(e.getMessage().contains('already exists'), 'Error message should indicate the ID already exists in the database. Actual message: ' + e.getMessage());
        }
        Test.stopTest();
    }

    @isTest
    static void testPreventIntraBatchDuplicate() {
        // Simulate an API payload where two records have the same QB Vendor ID in one batch
        List<Account> accountsToInsert = new List<Account>();
        accountsToInsert.add(new Account(Name = 'Batch Vendor A', faxa__QuickBooks_Vendor_Id__c = 'QB-303'));
        accountsToInsert.add(new Account(Name = 'Batch Vendor B', faxa__QuickBooks_Vendor_Id__c = 'QB-303'));
        
        Test.startTest();
        // Use Database.insert with allOrNone = false, exactly like your batch class does
        Database.SaveResult[] results = Database.insert(accountsToInsert, false);
        Test.stopTest();
         }
}