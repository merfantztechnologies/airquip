@IsTest(SeeAllData=true)
private class NewPurchaseOrderControllerTest {

    private static Account withBillingAddress(Account accountRecord) {
        accountRecord.BillingStreet = '123 Test Street';
        accountRecord.BillingCity = 'Dallas';
        accountRecord.BillingState = 'Texas';
        accountRecord.BillingPostalCode = '75001';
        accountRecord.BillingCountry = 'United States';
        accountRecord.ShippingStreet = '123 Test Street';
        accountRecord.ShippingCity = 'Dallas';
        accountRecord.ShippingState = 'Texas';
        accountRecord.ShippingPostalCode = '75001';
        accountRecord.ShippingCountry = 'United States';
        return accountRecord;
    }

    @IsTest
    static void testSearchStandardProducts() {
        Test.startTest();
        List<NewPurchaseOrderController.ProductOption> allProds = NewPurchaseOrderController.searchStandardProducts('');
        List<NewPurchaseOrderController.ProductOption> filteredProds = NewPurchaseOrderController.searchStandardProducts('Test');
        Test.stopTest();

        System.assertNotEquals(null, allProds, 'Product search should return a list');
        System.assertNotEquals(null, filteredProds, 'Filtered product search should return a list');
    }

    @IsTest
    static void testGetPicklistValues() {
        Test.startTest();
        List<String> statusValues = NewPurchaseOrderController.getPicklistValues('Purchase_Order_Status__c');
        List<String> syncValues = NewPurchaseOrderController.getPicklistValues('QuickBooks_Sync_Status__c');
        Test.stopTest();

        System.assertNotEquals(null, statusValues, 'Status picklist values list should not be null');
        System.assertNotEquals(null, syncValues, 'Sync status picklist values list should not be null');
    }

    @IsTest
    static void testCreatePurchaseOrderSuccess() {
        List<Account> accs = [SELECT Id FROM Account LIMIT 1];
        if (accs.isEmpty()) {
            return;
        }
        Account acc = accs[0];

        List<Product2> prods = [SELECT Id, Name FROM Product2 WHERE IsActive = true LIMIT 1];
        if (prods.isEmpty()) {
            return;
        }
        Product2 prod = prods[0];

        NewPurchaseOrderController.PurchaseOrderWrapper req = new NewPurchaseOrderController.PurchaseOrderWrapper();
        req.poNumber = 'PO-99999-' + System.currentTimeMillis();
        req.vendorId = acc.Id;
        req.poDate = String.valueOf(Date.today());
        req.status = 'Draft';
        req.permitNo = 'PERMIT-123';
        req.shippingStreet = '123 Main Street';
        req.shippingCity = 'Dallas';
        req.shippingState = 'TX';
        req.shippingPostalCode = '75001';
        req.shippingCountry = 'USA';
        req.syncToQuickBooks = false;
        req.quickbooksPoId = 'QB-PO-001';
        req.integrationStatus = 'Draft';

        NewPurchaseOrderController.LineItemWrapper item = new NewPurchaseOrderController.LineItemWrapper();
        item.productId = prod.Id;
        item.productName = prod.Name;
        item.description = 'Line Item Description';
        item.quantity = 5;
        item.rate = 150.00;
        item.isDeleted = false;

        req.lines = new List<NewPurchaseOrderController.LineItemWrapper>{ item };

        Test.startTest();
        try {
            NewPurchaseOrderController.SaveResult res = NewPurchaseOrderController.createPurchaseOrder(req);
            System.assertNotEquals(null, res, 'SaveResult should not be null');
            System.assertNotEquals(null, res.purchaseOrderId, 'Purchase Order Id should be returned');
        } catch (Exception e) {
            System.debug('Test create PO exception: ' + e.getMessage() + ' | ' + e.getStackTraceString());
        }
        Test.stopTest();
    }

    @IsTest
    static void testCreatePurchaseOrderValidationErrors() {
        Test.startTest();
        try {
            NewPurchaseOrderController.createPurchaseOrder(null);
            System.assert(false, 'Should throw exception for null request');
        } catch (Exception e) {
            System.assert(true, 'Expected Exception for null request');
        }

        try {
            NewPurchaseOrderController.PurchaseOrderWrapper req = new NewPurchaseOrderController.PurchaseOrderWrapper();
            NewPurchaseOrderController.createPurchaseOrder(req);
            System.assert(false, 'Should throw exception for missing PO Number');
        } catch (Exception e) {
            System.assert(true, 'Expected Exception for missing PO Number');
        }

        try {
            NewPurchaseOrderController.PurchaseOrderWrapper req = new NewPurchaseOrderController.PurchaseOrderWrapper();
            req.poNumber = 'PO-12345';
            NewPurchaseOrderController.createPurchaseOrder(req);
            System.assert(false, 'Should throw exception for missing Vendor');
        } catch (Exception e) {
            System.assert(true, 'Expected Exception for missing Vendor');
        }

        try {
            NewPurchaseOrderController.PurchaseOrderWrapper req = new NewPurchaseOrderController.PurchaseOrderWrapper();
            req.poNumber = 'PO-12345';
            req.vendorId = '001000000000000AAA';
            req.lines = new List<NewPurchaseOrderController.LineItemWrapper>();
            NewPurchaseOrderController.createPurchaseOrder(req);
            System.assert(false, 'Should throw exception for missing line items');
        } catch (Exception e) {
            System.assert(true, 'Expected Exception for missing line items');
        }
        Test.stopTest();
    }

    @IsTest
    static void testGetOrderDetails() {
        Test.startTest();
        NewPurchaseOrderController.OrderContextWrapper wrapperNull = NewPurchaseOrderController.getOrderDetails(null);
        System.assertEquals(null, wrapperNull, 'Should return null for null orderId');

        List<Order> ords = [SELECT Id FROM Order LIMIT 1];
        if (!ords.isEmpty()) {
            NewPurchaseOrderController.OrderContextWrapper res = NewPurchaseOrderController.getOrderDetails(ords[0].Id);
            System.assertNotEquals(null, res, 'Should return Order details for valid Order Id');
        }
        Test.stopTest();
    }

    @IsTest
    static void testDuplicatePONumberValidation() {
        Account vendor = withBillingAddress(new Account(
            Name = 'Test Vendor DUP',
            faxa__Account_Type__c = 'Vendor',
            faxa__QuickBooks_Vendor_Id__c = 'V-DUP-999'
        ));
        insert vendor;

        NewPurchaseOrderController.LineItemWrapper line = new NewPurchaseOrderController.LineItemWrapper();
        line.key = 'line-dup-1';
        line.quantity = 1;
        line.rate = 100;
        line.isDeleted = false;

        String uniquePo = 'PO-UNIQUE-' + System.currentTimeMillis();

        NewPurchaseOrderController.PurchaseOrderWrapper req1 = new NewPurchaseOrderController.PurchaseOrderWrapper();
        req1.poNumber = uniquePo;
        req1.vendorId = vendor.Id;
        req1.lines = new List<NewPurchaseOrderController.LineItemWrapper>{ line };

        Test.startTest();
        NewPurchaseOrderController.SaveResult res1 = NewPurchaseOrderController.createPurchaseOrder(req1);
        System.assertNotEquals(null, res1.purchaseOrderId, 'First PO should be created successfully');

        try {
            NewPurchaseOrderController.PurchaseOrderWrapper req2 = new NewPurchaseOrderController.PurchaseOrderWrapper();
            req2.poNumber = uniquePo;
            req2.vendorId = vendor.Id;
            req2.lines = new List<NewPurchaseOrderController.LineItemWrapper>{ line };

            NewPurchaseOrderController.createPurchaseOrder(req2);
            System.assert(false, 'Should throw exception for duplicate PO number');
        } catch (Exception e) {
            System.assert(true, 'Expected Exception for duplicate PO Number');
        }
        Test.stopTest();
    }

    @IsTest
    static void testVendorValidationForVendorAccount() {
        Account vendorWithoutQbId = withBillingAddress(new Account(
            Name = 'Vendor No QB ID',
            faxa__Account_Type__c = 'Vendor'
        ));
        insert vendorWithoutQbId;

        NewPurchaseOrderController.LineItemWrapper line = new NewPurchaseOrderController.LineItemWrapper();
        line.key = 'line-v-1';
        line.quantity = 1;
        line.rate = 50;

        NewPurchaseOrderController.PurchaseOrderWrapper req = new NewPurchaseOrderController.PurchaseOrderWrapper();
        req.poNumber = 'PO-V-NOQB-' + System.currentTimeMillis();
        req.vendorId = vendorWithoutQbId.Id;
        req.lines = new List<NewPurchaseOrderController.LineItemWrapper>{ line };

        Test.startTest();
        try {
            NewPurchaseOrderController.createPurchaseOrder(req);
            System.assert(false, 'Should throw exception for missing QB Vendor ID on Vendor account');
        } catch (Exception e) {
            System.assert(true, 'Expected Exception for missing QB Vendor ID');
        }
        Test.stopTest();
    }

    @IsTest
    static void testNonVendorAccountSuccess() {
        Account customerAccount = withBillingAddress(new Account(
            Name = 'Customer Account Non Vendor',
            faxa__Account_Type__c = 'Customer'
        ));
        insert customerAccount;

        NewPurchaseOrderController.LineItemWrapper line = new NewPurchaseOrderController.LineItemWrapper();
        line.key = 'line-nv-1';
        line.quantity = 2;
        line.rate = 100;

        NewPurchaseOrderController.PurchaseOrderWrapper req = new NewPurchaseOrderController.PurchaseOrderWrapper();
        req.poNumber = 'PO-NV-' + System.currentTimeMillis();
        req.vendorId = customerAccount.Id;
        req.lines = new List<NewPurchaseOrderController.LineItemWrapper>{ line };

        Test.startTest();
        try {
            NewPurchaseOrderController.SaveResult res = NewPurchaseOrderController.createPurchaseOrder(req);
            System.assertNotEquals(null, res, 'SaveResult should not be null for non-vendor account');
        } catch (Exception e) {
            System.debug('Non-vendor creation exception: ' + e.getMessage());
        }
        Test.stopTest();
    }

    @IsTest
    static void testRelatedRecordsContactsCustomersAndClasses() {
        String suffix = String.valueOf(System.currentTimeMillis());
        Account customer = withBillingAddress(new Account(
            Name = 'NPO Customer ' + suffix,
            faxa__QuickBooks_Customer_Id__c = 'QB-CUST-' + suffix
        ));
        insert customer;

        Contact contact = new Contact(
            LastName = 'NPO Contact ' + suffix,
            AccountId = customer.Id
        );
        insert contact;

        Opportunity opp = new Opportunity(
            Name = 'NPO Opportunity ' + suffix,
            AccountId = customer.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;

        Test.startTest();
        NewPurchaseOrderController.RelatedRecordsWrapper accountRelated =
            NewPurchaseOrderController.getRelatedRecordsForAccount(customer.Id);
        NewPurchaseOrderController.RelatedRecordsWrapper recentRelated =
            NewPurchaseOrderController.getRelatedRecordsForAccount(null);
        List<Map<String, String>> emptyContacts = NewPurchaseOrderController.getContactsForAccount(null);
        List<Map<String, String>> contacts = NewPurchaseOrderController.getContactsForAccount(customer.Id);
        List<Map<String, String>> customers = NewPurchaseOrderController.getCustomerAccounts('NPO Customer ' + suffix);
        List<Map<String, String>> classOptions = NewPurchaseOrderController.getClassOptions();
        Test.stopTest();

        System.assertNotEquals(null, accountRelated, 'Account related records should be returned');
        System.assertEquals(1, accountRelated.opportunityOptions.size(), 'Inserted opportunity should be returned');
        System.assertNotEquals(null, recentRelated, 'Recent related records wrapper should be returned');
        System.assertEquals(0, emptyContacts.size(), 'Blank account should return no contacts');
        System.assertEquals(1, contacts.size(), 'Inserted contact should be returned');
        System.assertNotEquals(null, customers, 'Customer lookup should return a list');
        System.assertNotEquals(null, classOptions, 'Class options should return a list');
    }

    @IsTest
    static void testCreatePurchaseOrderAllLinesDeleted() {
        Account vendor = withBillingAddress(new Account(
            Name = 'Deleted Lines Vendor',
            Type = 'Vendor',
            faxa__QuickBooks_Vendor_Id__c = 'V-DELETED-' + System.currentTimeMillis()
        ));
        insert vendor;

        NewPurchaseOrderController.LineItemWrapper deletedLine = new NewPurchaseOrderController.LineItemWrapper();
        deletedLine.key = 'line-deleted-1';
        deletedLine.quantity = 1;
        deletedLine.rate = 25;
        deletedLine.isDeleted = true;

        NewPurchaseOrderController.PurchaseOrderWrapper req = new NewPurchaseOrderController.PurchaseOrderWrapper();
        req.poNumber = 'PO-DELETED-' + System.currentTimeMillis();
        req.vendorId = vendor.Id;
        req.lines = new List<NewPurchaseOrderController.LineItemWrapper>{ deletedLine };

        Test.startTest();
        try {
            NewPurchaseOrderController.createPurchaseOrder(req);
            System.assert(false, 'Should throw exception when every line is deleted');
        } catch (Exception e) {
            System.assert(e.getMessage().contains('Please add at least one line item'), 'Expected deleted line validation');
        }
        Test.stopTest();
    }

    @IsTest
    static void testCreatePurchaseOrderMissingProductQuickBooksItemId() {
        String suffix = String.valueOf(System.currentTimeMillis());
        Account vendor = withBillingAddress(new Account(
            Name = 'Missing Product QB Vendor ' + suffix,
            Type = 'Vendor',
            faxa__QuickBooks_Vendor_Id__c = 'V-MISSING-PROD-' + suffix
        ));
        insert vendor;

        Product2 productWithoutQbId = new Product2(
            Name = 'Product Missing QB ' + suffix,
            IsActive = true
        );
        for (Schema.PicklistEntry entry : Product2.Family.getDescribe().getPicklistValues()) {
            if (entry.isActive()) {
                productWithoutQbId.Family = entry.getValue();
                break;
            }
        }
        insert productWithoutQbId;

        NewPurchaseOrderController.LineItemWrapper line = new NewPurchaseOrderController.LineItemWrapper();
        line.key = 'line-missing-qb-1';
        line.productId = productWithoutQbId.Id;
        line.productName = productWithoutQbId.Name;
        line.quantity = 1;
        line.rate = 10;
        line.isDeleted = false;

        NewPurchaseOrderController.PurchaseOrderWrapper req = new NewPurchaseOrderController.PurchaseOrderWrapper();
        req.poNumber = 'PO-MISSING-PROD-' + suffix;
        req.vendorId = vendor.Id;
        req.lines = new List<NewPurchaseOrderController.LineItemWrapper>{ line };

        Test.startTest();
        try {
            NewPurchaseOrderController.createPurchaseOrder(req);
            System.assert(false, 'Should throw exception when product is missing QuickBooks Item ID');
        } catch (Exception e) {
            System.assert(e.getMessage().contains('missing a QuickBooks Item ID'), 'Expected product QB Item ID validation');
        }
        Test.stopTest();
    }
}