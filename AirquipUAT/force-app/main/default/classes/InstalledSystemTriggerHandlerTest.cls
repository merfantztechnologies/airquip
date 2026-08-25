@IsTest
private class InstalledSystemTriggerHandlerTest {

    private static Product2 createProduct(String name, Boolean isInstalledSystem) {
        Product2 product = new Product2(
            Name = name,
            IsActive = true,
            Is_Installed_System__c = isInstalledSystem
        );
        insert product;
        return product;
    }

    private static Account createAccount() {
        Account account = new Account(Name = 'Installed System Test Account');
        insert account;
        return account;
    }

    private static fax__Installed_System__c createInstalledSystem(Id accountId, Id productId, String serialNumber) {
        fax__Installed_System__c installedSystem = new fax__Installed_System__c(
            fax__Site__c = accountId,
            fax__System_Name__c = productId,
            fax__Serial_Number__c = serialNumber
        );
        insert installedSystem;
        return installedSystem;
    }

    @IsTest
    static void testInsertSetsProductInstalledSystemFlag() {
        Product2 product = createProduct('Installed System Product', false);
        Account account = createAccount();

        Test.startTest();
        createInstalledSystem(account.Id, product.Id, 'SN-INSERT-001');
        Test.stopTest();

        Product2 result = [
            SELECT Is_Installed_System__c
            FROM Product2
            WHERE Id = :product.Id
        ];

        System.assertEquals(true, result.Is_Installed_System__c,
            'Product should be marked as an installed system when an Installed System record exists');
    }

    @IsTest
    static void testDeleteKeepsFlagTrueWhenAnotherInstalledSystemExists() {
        Product2 product = createProduct('Multiple Installed Systems Product', false);
        Account account = createAccount();

        fax__Installed_System__c firstInstalledSystem =
            createInstalledSystem(account.Id, product.Id, 'SN-DELETE-001');
        createInstalledSystem(account.Id, product.Id, 'SN-DELETE-002');

        Test.startTest();
        delete firstInstalledSystem;
        Test.stopTest();

        Product2 result = [
            SELECT Is_Installed_System__c
            FROM Product2
            WHERE Id = :product.Id
        ];

        System.assertEquals(true, result.Is_Installed_System__c,
            'Product should stay marked when another Installed System still exists');
    }

    @IsTest
    static void testDeleteLastInstalledSystemClearsProductFlag() {
        Product2 product = createProduct('Last Installed System Product', false);
        Account account = createAccount();
        fax__Installed_System__c installedSystem =
            createInstalledSystem(account.Id, product.Id, 'SN-DELETE-LAST-001');

        Test.startTest();
        delete installedSystem;
        Test.stopTest();

        Product2 result = [
            SELECT Is_Installed_System__c
            FROM Product2
            WHERE Id = :product.Id
        ];

        System.assertEquals(false, result.Is_Installed_System__c,
            'Product should be unmarked when its last Installed System is deleted');
    }

    @IsTest
    static void testUpdateMovesInstalledSystemFlagBetweenProducts() {
        Product2 oldProduct = createProduct('Old Installed System Product', false);
        Product2 newProduct = createProduct('New Installed System Product', false);
        Account account = createAccount();
        fax__Installed_System__c installedSystem =
            createInstalledSystem(account.Id, oldProduct.Id, 'SN-MOVE-001');

        installedSystem.fax__System_Name__c = newProduct.Id;

        Test.startTest();
        update installedSystem;
        Test.stopTest();

        Set<Id> productIds = new Set<Id>{oldProduct.Id, newProduct.Id};
        Map<Id, Product2> products = new Map<Id, Product2>([
            SELECT Id, Is_Installed_System__c
            FROM Product2
            WHERE Id IN :productIds
        ]);

        System.assertEquals(false, products.get(oldProduct.Id).Is_Installed_System__c,
            'Old Product should be unmarked when it has no remaining Installed Systems');
        System.assertEquals(true, products.get(newProduct.Id).Is_Installed_System__c,
            'New Product should be marked when the Installed System moves to it');
    }
}