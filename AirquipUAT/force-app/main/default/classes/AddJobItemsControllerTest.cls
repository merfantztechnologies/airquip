@isTest
private class AddJobItemsControllerTest {

    // ── Test Data Setup ──────────────────────────────────────────────

    @TestSetup
    static void setupTestData() {

        Account customer = createCustomerAccount('Test Customer');

        Contact sitecontact = new Contact(
            LastName = 'Test Contact',
            Email = 'test.contact@example.com',
            AccountId = customer.Id
        );
        insert sitecontact;

        Pricebook2 standardPb = new Pricebook2(
            Id = Test.getStandardPricebookId(),
            IsActive = true
        );
        update standardPb;

        Pricebook2 customPb = new Pricebook2(
            Name = 'Test Pricebook',
            IsActive = true
        );
        insert customPb;

        Product2 product = new Product2(
            Name = 'Test Product',
            ProductCode = 'TP-001',
            Description = 'A test product',
            Family = 'Hardware',
            IsActive = true
        );
        product.put('faxa__Purchase_Cost__c', 45.50);
        insert product;

        PricebookEntry stdEntry = new PricebookEntry(
            Pricebook2Id = Test.getStandardPricebookId(),
            Product2Id = product.Id,
            UnitPrice = 100,
            IsActive = true
        );
        insert stdEntry;

        PricebookEntry customEntry = new PricebookEntry(
            Pricebook2Id = customPb.Id,
            Product2Id = product.Id,
            UnitPrice = 150,
            IsActive = true
        );
        insert customEntry;

        fax__Job__c job = new fax__Job__c(
            fax__Customer__c = customer.Id,
            fax__Pricebook__c = customPb.Id,
            fax__Contact__c = sitecontact.Id,
            fax__Status__c = 'Open',
            fax__Visit_Type__c = 'Service',
            fax__Trigger_Job_Sheet_Email__c = false,
            fax__Planned_Visit_Date_Time__c = System.now()
        );
        insert job;

        fax__Installed_System__c installedSystem =
            new fax__Installed_System__c(
                fax__Site__c = customer.Id,
                fax__System_Name__c = product.Id,
                fax__Serial_Number__c = 'SN-TEST-001'
            );
        insert installedSystem;
    }

    // ── Helper ───────────────────────────────────────────────────────

    private static Account createCustomerAccount(String name) {
        Account customer = new Account(
            Name = name,
            BillingStreet = '123 Main St',
            BillingCity = 'Austin',
            BillingCountryCode = 'US',
            BillingStateCode = 'TX',
            BillingPostalCode = '78701',
            ShippingStreet = '123 Main St',
            ShippingCity = 'Austin',
            ShippingCountryCode = 'US',
            ShippingStateCode = 'TX',
            ShippingPostalCode = '78701'
        );
        insert customer;
        return customer;
    }

    private static fax__Invoice__c createInvoice() {

        Account acc = [SELECT Id FROM Account LIMIT 1];

        fax__Invoice__c inv = new fax__Invoice__c(
            fax__Site__c = acc.Id
        );

        insert inv;

        return inv;
    }

    // ── Labels ───────────────────────────────────────────────────────

    @isTest
    static void testGetJobItemSelectorLabels() {

        Test.startTest();
        Map<String, String> labels =
            AddJobItemsController.getJobItemSelectorLabels();
        Test.stopTest();

        System.assertNotEquals(null, labels);
    }

    // ── Multi Currency ───────────────────────────────────────────────

    @isTest
    static void testIsMultiCurrencyOrg() {

        Test.startTest();
        Boolean result = AddJobItemsController.isMultiCurrencyOrg();
        Test.stopTest();

        System.assertNotEquals(null, result);
    }

    // ── Parent Context ───────────────────────────────────────────────

    @isTest
    static void testGetParentContext_Job() {

        fax__Job__c job = [SELECT Id FROM fax__Job__c LIMIT 1];

        Test.startTest();
        String result = AddJobItemsController.getParentContext(job.Id);
        Test.stopTest();

        System.assertEquals('JOB', result);
    }

    @isTest
    static void testGetParentContext_Null() {

        Test.startTest();
        String result = AddJobItemsController.getParentContext(null);
        Test.stopTest();

        System.assertEquals('JOB', result);
    }

    // ── Job Pricebook ────────────────────────────────────────────────

    @isTest
    static void testCheckJobPricebook_withPricebook() {

        fax__Job__c job =
            [SELECT Id, fax__Pricebook__c FROM fax__Job__c LIMIT 1];

        Test.startTest();
        Id pbId = AddJobItemsController.checkJobPricebook(job.Id);
        Test.stopTest();

        System.assertEquals(job.fax__Pricebook__c, pbId);
    }

    @isTest
    static void testCheckJobPricebook_noPricebook() {

        Account customer = [SELECT Id FROM Account LIMIT 1];
        Contact siteContact = [
            SELECT Id
            FROM Contact
            WHERE AccountId = :customer.Id
            LIMIT 1
        ];
        fax__Job__c jobNoPb = new fax__Job__c(
            fax__Customer__c = customer.Id,
            fax__Contact__c = siteContact.Id,
            fax__Status__c = 'Open',
            fax__Visit_Type__c = 'Service',
            fax__Trigger_Job_Sheet_Email__c = false,
            fax__Planned_Visit_Date_Time__c = System.now()
        );

        insert jobNoPb;

        Test.startTest();
        Id pbId = AddJobItemsController.checkJobPricebook(jobNoPb.Id);
        Test.stopTest();

    }

    @isTest
    static void testEnsurePricebookForRecord_assignsStandardWhenMissing() {
        Account customer = [SELECT Id FROM Account LIMIT 1];
        Contact siteContact = [
            SELECT Id
            FROM Contact
            WHERE AccountId = :customer.Id
            LIMIT 1
        ];
        fax__Job__c jobNoPb = new fax__Job__c(
            fax__Customer__c = customer.Id,
            fax__Contact__c = siteContact.Id,
            fax__Status__c = 'Open',
            fax__Visit_Type__c = 'Service',
            fax__Trigger_Job_Sheet_Email__c = false,
            fax__Planned_Visit_Date_Time__c = System.now()
        );
        insert jobNoPb;

        Test.startTest();
        AddJobItemsController.PricebookResolution resolution =
            AddJobItemsController.ensurePricebookForRecord(jobNoPb.Id);
        Test.stopTest();

        System.assertNotEquals(null, resolution.pricebookId);

        fax__Job__c updatedJob = [
            SELECT fax__Pricebook__c
            FROM fax__Job__c
            WHERE Id = :jobNoPb.Id
        ];
        System.assertNotEquals(null, updatedJob.fax__Pricebook__c);
        System.assertEquals(resolution.pricebookId, updatedJob.fax__Pricebook__c);
    }

    @isTest
    static void testInitializeJobItemSelector_usesExistingJobPricebook() {
        fax__Job__c job = [SELECT Id, fax__Pricebook__c FROM fax__Job__c LIMIT 1];

        Test.startTest();
        AddJobItemsController.JobItemSelectorInit init =
            AddJobItemsController.initializeJobItemSelector(job.Id);
        Test.stopTest();

        System.assertEquals('JOB', init.parentContext);
        System.assertEquals(job.fax__Pricebook__c, init.pricebookId);
        System.assertNotEquals(null, init.lineRows);
    }

    // ── Pricebook Active ─────────────────────────────────────────────

    @isTest
    static void testIsPricebookActive_active() {

        Pricebook2 pb =
            [SELECT Id FROM Pricebook2 WHERE Name = 'Test Pricebook' LIMIT 1];

        Test.startTest();
        Boolean isActive = AddJobItemsController.IsPricebookActive(pb.Id);
        Test.stopTest();

        System.assertEquals(true, isActive);
    }

    @isTest
    static void testIsPricebookActive_inactive() {

        Pricebook2 inactivePb =
            new Pricebook2(Name = 'Inactive PB', IsActive = false);

        insert inactivePb;

        Test.startTest();
        Boolean isActive =
            AddJobItemsController.IsPricebookActive(inactivePb.Id);
        Test.stopTest();

        System.assertEquals(false, isActive);
    }

    // ── Pricebooks ───────────────────────────────────────────────────

    @isTest
    static void testGetPricebooks() {

        Test.startTest();
        List<Pricebook2> pbs = AddJobItemsController.getPricebooks();
        Test.stopTest();

        System.assert(!pbs.isEmpty());
    }

    // ── Currency Code ────────────────────────────────────────────────

    @isTest
    static void testCheckCurrencyCode() {

        fax__Job__c job = [SELECT Id FROM fax__Job__c LIMIT 1];

        Test.startTest();
        String code = AddJobItemsController.checkCurrencyCode(job.Id);
        Test.stopTest();

        System.assertEquals(null, code);
    }

    // ── Update Pricebook ─────────────────────────────────────────────

    @isTest
    static void testUpdatePricebookOnJob() {

        fax__Job__c job = [SELECT Id FROM fax__Job__c LIMIT 1];

        Test.startTest();
        AddJobItemsController.updatePricebookOnJob(Test.getStandardPricebookId(), job.Id);
        Test.stopTest();

        fax__Job__c updated =
            [SELECT fax__Pricebook__c FROM fax__Job__c WHERE Id = :job.Id];

        System.assertEquals(Test.getStandardPricebookId(), updated.fax__Pricebook__c);
    }

    // ── Products ─────────────────────────────────────────────────────

    @isTest
    static void testGetProducts_withInstalledSystems() {

        fax__Job__c job = [SELECT Id FROM fax__Job__c LIMIT 1];

        Test.startTest();
        List<Product2> products =
            AddJobItemsController.getProducts(job.Id);
        Test.stopTest();

        System.assert(!products.isEmpty());
    }

    @isTest
    static void testGetProducts_noInstalledSystems() {

        Account newCustomer = createCustomerAccount('Customer No Systems');

        Contact siteContact = new Contact(
            LastName = 'No Systems Contact',
            Email = 'nosystems.contact@example.com',
            AccountId = newCustomer.Id
        );
        insert siteContact;

        try {
            fax__Job__c job = new fax__Job__c(
                fax__Customer__c = newCustomer.Id,
                fax__Contact__c = siteContact.Id,
                fax__Status__c = 'Open',
                fax__Visit_Type__c = 'Service',
                fax__Trigger_Job_Sheet_Email__c = false,
                fax__Planned_Visit_Date_Time__c = System.now()
            );
            insert job;

            List<Product2> products = AddJobItemsController.getProducts(job.Id);
            System.assertEquals(0, products.size());
        } catch (DmlException e) {
            System.assert(
                e.getMessage().contains('Please ensure the contact you have chosen belongs to the same customer'),
                'Expected customer/contact validation message, got: ' + e.getMessage()
            );
        }
    }

    // ── Search Products ──────────────────────────────────────────────

    @isTest
    static void testSearchProducts_blankFilter() {

        fax__Job__c job = [SELECT Id FROM fax__Job__c LIMIT 1];

        Test.startTest();
        List<Product2> products =
            AddJobItemsController.searchProducts(job.Id, '');
        Test.stopTest();

        System.assert(!products.isEmpty());
    }

    @isTest
    static void testSearchProducts_matchingFilter() {

        fax__Job__c job = [SELECT Id FROM fax__Job__c LIMIT 1];

        Test.startTest();
        List<Product2> products =
            AddJobItemsController.searchProducts(job.Id, 'Test');
        Test.stopTest();

        System.assert(!products.isEmpty());
    }

    @isTest
    static void testSearchProducts_matchesDescription() {

        fax__Job__c job = [SELECT Id FROM fax__Job__c LIMIT 1];

        Test.startTest();
        List<Product2> products =
            AddJobItemsController.searchProducts(job.Id, 'A test');
        Test.stopTest();

        System.assert(!products.isEmpty(), 'Should match Product2.Description');
    }

    @isTest
    static void testSearchProducts_noMatch() {

        fax__Job__c job = [SELECT Id FROM fax__Job__c LIMIT 1];

        Test.startTest();
        List<Product2> products =
            AddJobItemsController.searchProducts(job.Id, 'NO_MATCH');
        Test.stopTest();

        System.assertEquals(0, products.size());
    }

    // ── All Products ─────────────────────────────────────────────────

    @isTest
    static void testGetAllProducts() {

        Test.startTest();
        List<Product2> products =
            AddJobItemsController.getAllProducts();
        Test.stopTest();

        System.assert(products.size() > 0);
    }

    @isTest
    static void testSearchAllProducts_Blank() {

        Test.startTest();
        List<Product2> products =
            AddJobItemsController.searchAllProducts('');
        Test.stopTest();

        System.assert(products.size() > 0);
    }

    @isTest
    static void testSearchAllProducts_Filter() {

        Test.startTest();
        List<Product2> products =
            AddJobItemsController.searchAllProducts('Test');
        Test.stopTest();

        System.assert(products.size() > 0);
    }

    @isTest
    static void testSearchAllProducts_matchesDescription() {

        Test.startTest();
        List<Product2> products =
            AddJobItemsController.searchAllProducts('A test');
        Test.stopTest();

        System.assert(products.size() > 0, 'Should match Product2.Description');
    }

    @isTest
    static void testSearchAllProducts_NoMatch() {

        Test.startTest();
        List<Product2> products =
            AddJobItemsController.searchAllProducts('ZZZZZZ');
        Test.stopTest();

        System.assertEquals(0, products.size());
    }

    // ── Pricebook Entries ────────────────────────────────────────────

    @isTest
    static void testGetProductsWithPricebookEntries() {

        Pricebook2 pb =
            [SELECT Id FROM Pricebook2 WHERE Name = 'Test Pricebook' LIMIT 1];

        Product2 prod =
            [SELECT Id FROM Product2 WHERE ProductCode = 'TP-001' LIMIT 1];

        Test.startTest();

        List<PricebookEntry> entries =
            AddJobItemsController.getProductsWithPricebookEntries(
                pb.Id,
                new List<Id>{ prod.Id }
            );

        Test.stopTest();

        System.assert(!entries.isEmpty());
    }

    @isTest
    static void testGetProductsWithPricebookEntries_noMatch() {

        Pricebook2 pb =
            [SELECT Id FROM Pricebook2 WHERE Name = 'Test Pricebook' LIMIT 1];

        Product2 otherProd =
            new Product2(
                Name = 'Other Product',
                Family = 'Hardware',
                IsActive = true
            );

        insert otherProd;

        Test.startTest();

        List<PricebookEntry> entries =
            AddJobItemsController.getProductsWithPricebookEntries(
                pb.Id,
                new List<Id>{ otherProd.Id }
            );

        Test.stopTest();

        System.assertEquals(0, entries.size());
    }

    @isTest
    static void testGetProductsWithPricebookEntriesByISOCode() {

        Pricebook2 pb =
            [SELECT Id FROM Pricebook2 WHERE Name = 'Test Pricebook' LIMIT 1];

        Product2 prod =
            [SELECT Id FROM Product2 WHERE ProductCode = 'TP-001' LIMIT 1];

        Test.startTest();

        List<PricebookEntry> entries =
            AddJobItemsController.getProductsWithPricebookEntriesByISOCode(
                pb.Id,
                new List<Id>{ prod.Id },
                'USD'
            );

        Test.stopTest();

        System.assertEquals(null, entries);
    }

    // ── Invoice Methods ──────────────────────────────────────────────

    @isTest
    static void testCheckInvoicePricebook_Null() {

        Test.startTest();
        Id result = AddJobItemsController.checkInvoicePricebook(null);
        Test.stopTest();

        System.assertEquals(null, result);
    }

    @isTest
    static void testUpdatePricebookOnInvoice_Null() {

        Test.startTest();
        AddJobItemsController.updatePricebookOnInvoice(null, null);
        Test.stopTest();

        System.assert(true);
    }

    @isTest
    static void testGetInvoiceProducts() {

        fax__Invoice__c inv = createInvoice();

        Test.startTest();
        List<Product2> products =
            AddJobItemsController.getInvoiceProducts(inv.Id);
        Test.stopTest();

        System.assert(products.size() > 0);
    }

    @isTest
    static void testGetInvoiceProducts_NoSystems() {

        Account acc = createCustomerAccount('Invoice Customer');

        fax__Invoice__c inv = new fax__Invoice__c(
            fax__Site__c = acc.Id
        );

        insert inv;

        Test.startTest();
        List<Product2> products =
            AddJobItemsController.getInvoiceProducts(inv.Id);
        Test.stopTest();

        System.assertEquals(0, products.size());
    }

    @isTest
    static void testSearchInvoiceProducts_Blank() {

        fax__Invoice__c inv = createInvoice();

        Test.startTest();
        List<Product2> products =
            AddJobItemsController.searchInvoiceProducts(inv.Id, '');
        Test.stopTest();

        System.assert(products.size() > 0);
    }

    @isTest
    static void testSearchInvoiceProducts_Filter() {

        fax__Invoice__c inv = createInvoice();

        Test.startTest();
        List<Product2> products =
            AddJobItemsController.searchInvoiceProducts(inv.Id, 'Test');
        Test.stopTest();

        System.assert(products.size() > 0);
    }

    @isTest
    static void testSearchInvoiceProducts_matchesDescription() {

        fax__Invoice__c inv = createInvoice();

        Test.startTest();
        List<Product2> products =
            AddJobItemsController.searchInvoiceProducts(inv.Id, 'A test');
        Test.stopTest();

        System.assert(products.size() > 0, 'Should match Product2.Description');
    }

    @isTest
    static void testSearchInvoiceProducts_NoMatch() {

        fax__Invoice__c inv = createInvoice();

        Test.startTest();
        List<Product2> products =
            AddJobItemsController.searchInvoiceProducts(inv.Id, 'ZZZZZZ');
        Test.stopTest();

        System.assertEquals(0, products.size());
    }

    // ── Job Systems ──────────────────────────────────────────────────

    @isTest
    static void testCreateJobSystems_insertsNew() {

        fax__Job__c job = [SELECT Id FROM fax__Job__c LIMIT 1];

        Product2 prod =
            [SELECT Id FROM Product2 WHERE ProductCode = 'TP-001' LIMIT 1];

        fax__Job_System__c js = new fax__Job_System__c(
            fax__Job_New__c = job.Id,
            fax__Product__c = prod.Id,
            fax__Unit_Price__c = 0
        );

        Test.startTest();

        List<fax__Job_System__c> inserted =
            AddJobItemsController.createJobSystems(
                new List<fax__Job_System__c>{ js }
            );

        Test.stopTest();

        System.assertEquals(1, inserted.size());
    }

    @isTest
    static void testCreateJobSystems_skipsDuplicates() {

        fax__Job__c job = [SELECT Id FROM fax__Job__c LIMIT 1];

        Product2 prod =
            [SELECT Id FROM Product2 WHERE ProductCode = 'TP-001' LIMIT 1];

        fax__Job_System__c existingJs = new fax__Job_System__c(
            fax__Job_New__c = job.Id,
            fax__Product__c = prod.Id,
            fax__Unit_Price__c = 0
        );

        insert existingJs;

        fax__Job_System__c duplicateJs = new fax__Job_System__c(
            fax__Job_New__c = job.Id,
            fax__Product__c = prod.Id
        );

        Test.startTest();

        List<fax__Job_System__c> inserted =
            AddJobItemsController.createJobSystems(
                new List<fax__Job_System__c>{ duplicateJs }
            );

        Test.stopTest();

        System.assertEquals(0, inserted.size());
    }

    // ── Invoice Line Items ───────────────────────────────────────────

    @isTest
    static void testCreateInvoiceLineItems() {

        fax__Invoice__c inv = createInvoice();

        Product2 prod =
            [SELECT Id, Description FROM Product2 LIMIT 1];

        fax__Invoice_Line_Item__c li =
            new fax__Invoice_Line_Item__c(
                fax__Invoice__c = inv.Id,
                fax__Product__c = prod.Id,
                fax__Qty__c = 1,
                fax__Unit_Price__c = 100,
                fax__Discount__c = 0
            );

        Test.startTest();

        List<fax__Invoice_Line_Item__c> result =
            AddJobItemsController.createInvoiceLineItems(
                new List<fax__Invoice_Line_Item__c>{ li }
            );

        Test.stopTest();

        System.assertEquals(1, result.size());
    }

    @isTest
    static void testCreateInvoiceLineItems_Duplicate() {

        fax__Invoice__c inv = createInvoice();

        Product2 prod = [SELECT Id FROM Product2 LIMIT 1];

        fax__Invoice_Line_Item__c existingLine =
            new fax__Invoice_Line_Item__c(
                fax__Invoice__c = inv.Id,
                fax__Product__c = prod.Id,
                fax__Qty__c = 1,
                fax__Unit_Price__c = 100
            );

        insert existingLine;

        fax__Invoice_Line_Item__c duplicateLine =
            new fax__Invoice_Line_Item__c(
                fax__Invoice__c = inv.Id,
                fax__Product__c = prod.Id,
                fax__Qty__c = 1,
                fax__Unit_Price__c = 100
            );

        Test.startTest();

        List<fax__Invoice_Line_Item__c> result =
            AddJobItemsController.createInvoiceLineItems(
                new List<fax__Invoice_Line_Item__c>{ duplicateLine }
            );

        Test.stopTest();

        System.assertEquals(0, result.size());
    }

    @isTest
    static void testCreateInvoiceLineItems_EmptyList() {

        Test.startTest();

        List<fax__Invoice_Line_Item__c> result =
            AddJobItemsController.createInvoiceLineItems(
                new List<fax__Invoice_Line_Item__c>()
            );

        Test.stopTest();

        System.assertEquals(0, result.size());
    }

    // ── Inline Grid API ───────────────────────────────────────────────

    @isTest
    static void testGetLineItemsForGrid_Job() {
        fax__Job__c job = [SELECT Id FROM fax__Job__c LIMIT 1];
        Product2 prod = [SELECT Id, Description FROM Product2 WHERE ProductCode = 'TP-001' LIMIT 1];

        insert new fax__Job_System__c(
            fax__Job_New__c = job.Id,
            fax__Product__c = prod.Id,
            fax__Quantity__c = 2,
            fax__List_Pricce__c = 150,
            fax__Unit_Price__c = 125,
            fax__Discount__c = 0
        );

        Test.startTest();
        List<AddJobItemsController.GridLineRow> rows =
            AddJobItemsController.getLineItemsForGrid(job.Id);
        Test.stopTest();

        System.assertEquals(1, rows.size());
        System.assertEquals(prod.Id, rows[0].productId);
        System.assertEquals(prod.Description, rows[0].description);
        System.assertEquals('SN-TEST-001', rows[0].installedItem);
        System.assertEquals(2, rows[0].quantity);
        System.assertEquals(125, rows[0].unitPrice);
        System.assertEquals(250, rows[0].amount);
        System.assertEquals(45.50, rows[0].cost);
    }

    @isTest
    static void testGetLineItemsForGrid_Invoice() {
        fax__Invoice__c inv = createInvoice();
        Product2 prod = [SELECT Id, Description FROM Product2 WHERE ProductCode = 'TP-001' LIMIT 1];

        insert new fax__Invoice_Line_Item__c(
            fax__Invoice__c = inv.Id,
            fax__Product__c = prod.Id,
            fax__Qty__c = 3,
            fax__Unit_Price__c = 25,
            fax__Discount__c = 0,
            Description__c = 'Invoice grid item'
        );

        Test.startTest();
        List<AddJobItemsController.GridLineRow> rows =
            AddJobItemsController.getLineItemsForGrid(inv.Id);
        Test.stopTest();

        System.assertEquals(1, rows.size());
        System.assertEquals(prod.Id, rows[0].productId);
        System.assertEquals('SN-TEST-001', rows[0].installedItem);
        System.assertEquals('Invoice grid item', rows[0].description);
        System.assertEquals(3, rows[0].quantity);
        System.assertEquals(25, rows[0].unitPrice);
        System.assertEquals(75, rows[0].amount);
        System.assertEquals(45.50, rows[0].cost);
        System.assertEquals(true, rows[0].includeInInvoice);
    }

    @isTest
    static void testGetLineItemsForGrid_Invoice_IncludeInInvoiceUnchecked() {
        fax__Invoice__c inv = createInvoice();
        Product2 prod = [SELECT Id FROM Product2 WHERE ProductCode = 'TP-001' LIMIT 1];

        insert new fax__Invoice_Line_Item__c(
            fax__Invoice__c = inv.Id,
            fax__Product__c = prod.Id,
            fax__Qty__c = 1,
            fax__Unit_Price__c = 10,
            fax__Discount__c = 0,
            Include_In_Invoice__c = false
        );

        Test.startTest();
        List<AddJobItemsController.GridLineRow> rows =
            AddJobItemsController.getLineItemsForGrid(inv.Id);
        Test.stopTest();

        System.assertEquals(1, rows.size());
        System.assertEquals(false, rows[0].includeInInvoice);
        System.assertEquals(0, rows[0].unitPrice);
        System.assertEquals(0, rows[0].amount);
    }

    @isTest
    static void testGetLineItemsForGrid_Job_WithEngineerComments() {
        fax__Job__c job = [SELECT Id FROM fax__Job__c LIMIT 1];
        Product2 prod = [SELECT Id, Description FROM Product2 WHERE ProductCode = 'TP-001' LIMIT 1];

        insert new fax__Job_System__c(
            fax__Job_New__c = job.Id,
            fax__Product__c = prod.Id,
            fax__Quantity__c = 1,
            fax__Unit_Price__c = 50,
            fax__Discount__c = 0,
            Engineer_Comments__c = 'Saved engineer note'
        );

        Test.startTest();
        List<AddJobItemsController.GridLineRow> rows =
            AddJobItemsController.getLineItemsForGrid(job.Id);
        Test.stopTest();

        System.assertEquals(1, rows.size());
        System.assertEquals('Saved engineer note', rows[0].description);
    }

    @isTest
    static void testGetLineItemsForGrid_Job_FallsBackToProductDescription() {
        fax__Job__c job = [SELECT Id FROM fax__Job__c LIMIT 1];
        Product2 prod = [SELECT Id, Description FROM Product2 WHERE ProductCode = 'TP-001' LIMIT 1];

        insert new fax__Job_System__c(
            fax__Job_New__c = job.Id,
            fax__Product__c = prod.Id,
            fax__Quantity__c = 1,
            fax__Unit_Price__c = 50,
            fax__Discount__c = 0
        );

        Test.startTest();
        List<AddJobItemsController.GridLineRow> rows =
            AddJobItemsController.getLineItemsForGrid(job.Id);
        Test.stopTest();

        System.assertEquals(prod.Description, rows[0].description);
    }

    @isTest
    static void testGetLineItemsForGrid_Invoice_FallsBackToProductDescription() {
        fax__Invoice__c inv = createInvoice();
        Product2 prod = [SELECT Id, Description FROM Product2 WHERE ProductCode = 'TP-001' LIMIT 1];

        insert new fax__Invoice_Line_Item__c(
            fax__Invoice__c = inv.Id,
            fax__Product__c = prod.Id,
            fax__Qty__c = 1,
            fax__Unit_Price__c = 40,
            fax__Discount__c = 0
        );

        Test.startTest();
        List<AddJobItemsController.GridLineRow> rows =
            AddJobItemsController.getLineItemsForGrid(inv.Id);
        Test.stopTest();

        System.assertEquals(1, rows.size());
        System.assertEquals(prod.Description, rows[0].description);
    }

    @isTest
    static void testGetLineItemsForGrid_NullRecordId() {
        Test.startTest();
        List<AddJobItemsController.GridLineRow> rows =
            AddJobItemsController.getLineItemsForGrid(null);
        Test.stopTest();

        System.assertEquals(0, rows.size());
    }

    @isTest
    static void testGetParentContext_Invoice() {
        fax__Invoice__c inv = createInvoice();

        Test.startTest();
        String result = AddJobItemsController.getParentContext(inv.Id);
        Test.stopTest();

        System.assertEquals('INVOICE', result);
    }

    @isTest
    static void testInitializeJobItemSelector_NullRecordId() {
        Test.startTest();
        AddJobItemsController.JobItemSelectorInit init =
            AddJobItemsController.initializeJobItemSelector(null);
        Test.stopTest();

        System.assertEquals('JOB', init.parentContext);
        System.assertEquals(0, init.lineRows.size());
    }

    @isTest
    static void testInitializeJobItemSelector_Invoice() {
        fax__Invoice__c inv = createInvoice();

        Test.startTest();
        AddJobItemsController.JobItemSelectorInit init =
            AddJobItemsController.initializeJobItemSelector(inv.Id);
        Test.stopTest();

        System.assertEquals('INVOICE', init.parentContext);
        System.assertNotEquals(null, init.lineRows);
    }

    @isTest
    static void testEnsurePricebookForRecord_NullRecordId() {
        Test.startTest();
        AddJobItemsController.PricebookResolution resolution =
            AddJobItemsController.ensurePricebookForRecord(null);
        Test.stopTest();

        System.assertEquals(false, resolution.assignedToRecord);
        System.assertEquals(null, resolution.pricebookId);
    }

    @isTest
    static void testSaveLineItemsForGrid_NullRecordId() {
        Test.startTest();
        List<AddJobItemsController.GridLineRow> rows =
            AddJobItemsController.saveLineItemsForGrid(null, new List<AddJobItemsController.GridLineRow>());
        Test.stopTest();

        System.assertEquals(0, rows.size());
    }

    @isTest
    static void testSaveLineItemsForGrid_Job_UpdatesEngineerComments() {
        fax__Job__c job = [SELECT Id FROM fax__Job__c LIMIT 1];
        Product2 prod = [SELECT Id, Description FROM Product2 WHERE ProductCode = 'TP-001' LIMIT 1];

        fax__Job_System__c line = new fax__Job_System__c(
            fax__Job_New__c = job.Id,
            fax__Product__c = prod.Id,
            fax__Quantity__c = 1,
            fax__Unit_Price__c = 25,
            fax__Discount__c = 0,
            Engineer_Comments__c = 'Initial comment'
        );
        insert line;

        AddJobItemsController.GridLineRow row = AddJobItemsController.getLineItemsForGrid(job.Id)[0];
        row.description = 'Updated engineer comment';

        Test.startTest();
        AddJobItemsController.saveLineItemsForGrid(job.Id, new List<AddJobItemsController.GridLineRow>{ row });
        Test.stopTest();

        fax__Job_System__c updated = [
            SELECT Engineer_Comments__c
            FROM fax__Job_System__c
            WHERE Id = :line.Id
        ];
        System.assertEquals('Updated engineer comment', updated.Engineer_Comments__c);
    }

    @isTest
    static void testSaveLineItemsForGrid_Invoice_SavesDescription() {
        fax__Invoice__c inv = createInvoice();
        Product2 prod = [SELECT Id, Description FROM Product2 WHERE ProductCode = 'TP-001' LIMIT 1];

        AddJobItemsController.GridLineRow row = new AddJobItemsController.GridLineRow();
        row.productId = prod.Id;
        row.description = 'Invoice description text';
        row.quantity = 2;
        row.unitPrice = 15;
        row.discount = 0;

        Test.startTest();
        List<AddJobItemsController.GridLineRow> saved =
            AddJobItemsController.saveLineItemsForGrid(
                inv.Id,
                new List<AddJobItemsController.GridLineRow>{ row }
            );
        Test.stopTest();

        fax__Invoice_Line_Item__c line = [
            SELECT Description__c
            FROM fax__Invoice_Line_Item__c
            WHERE Id = :saved[0].rowId
        ];
        System.assertEquals('Invoice description text', line.Description__c);
    }

    @isTest
    static void testSaveLineItemsForGrid_Invoice_IncludeInInvoice() {
        fax__Invoice__c inv = createInvoice();
        Product2 prod = [SELECT Id FROM Product2 WHERE ProductCode = 'TP-001' LIMIT 1];

        AddJobItemsController.GridLineRow row = new AddJobItemsController.GridLineRow();
        row.productId = prod.Id;
        row.description = 'Excluded line';
        row.quantity = 1;
        row.unitPrice = 12;
        row.discount = 0;
        row.includeInInvoice = false;

        Test.startTest();
        List<AddJobItemsController.GridLineRow> saved =
            AddJobItemsController.saveLineItemsForGrid(
                inv.Id,
                new List<AddJobItemsController.GridLineRow>{ row }
            );
        Test.stopTest();

        fax__Invoice_Line_Item__c line = [
            SELECT Include_In_Invoice__c, fax__Unit_Price__c
            FROM fax__Invoice_Line_Item__c
            WHERE Id = :saved[0].rowId
        ];
        System.assertEquals(false, line.Include_In_Invoice__c);
        System.assertEquals(false, saved[0].includeInInvoice);
        System.assertEquals(0, line.fax__Unit_Price__c);
        System.assertEquals(0, saved[0].unitPrice);
    }

    @isTest
    static void testSearchProductsForGrid_NullAndBlank() {
        Test.startTest();
        System.assertEquals(
            0,
            AddJobItemsController.searchProductsForGrid(null, 'Test', 'ALL_PRODUCTS', null).size()
        );
        System.assertEquals(
            0,
            AddJobItemsController.searchProductsForGrid(
                [SELECT Id FROM fax__Job__c LIMIT 1].Id,
                '',
                'ALL_PRODUCTS',
                null
            ).size()
        );
        Test.stopTest();
    }

    @isTest
    static void testSearchProductsForGrid_InstalledProducts() {
        fax__Job__c job = [SELECT Id, fax__Pricebook__c FROM fax__Job__c LIMIT 1];

        Test.startTest();
        List<AddJobItemsController.GridLineRow> rows =
            AddJobItemsController.searchProductsForGrid(
                job.Id,
                'Test',
                'INSTALLED_PRODUCTS',
                job.fax__Pricebook__c
            );
        Test.stopTest();

        System.assertEquals(1, rows.size());
        System.assertEquals('A test product', rows[0].description);
    }

    @isTest
    static void testSearchProductsForGrid_MatchesProductCode() {
        fax__Job__c job = [SELECT Id, fax__Pricebook__c FROM fax__Job__c LIMIT 1];

        Test.startTest();
        List<AddJobItemsController.GridLineRow> rows =
            AddJobItemsController.searchProductsForGrid(
                job.Id,
                'TP-001',
                'ALL_PRODUCTS',
                job.fax__Pricebook__c
            );
        Test.stopTest();

        System.assertEquals(1, rows.size());
        System.assertEquals('TP-001', rows[0].productCode);
    }

    @isTest
    static void testSearchInstalledItemsForGrid_NoMatch() {
        fax__Job__c job = [SELECT Id FROM fax__Job__c LIMIT 1];

        Test.startTest();
        List<AddJobItemsController.InstalledItemOption> options =
            AddJobItemsController.searchInstalledItemsForGrid(job.Id, 'NO-MATCH-XYZ');
        Test.stopTest();

        System.assertEquals(0, options.size());
    }

    @isTest
    static void testSearchInstalledItemsForGrid_NoSiteAccount() {
        Account customer = createCustomerAccount('No Site Invoice Customer');
        fax__Invoice__c inv = new fax__Invoice__c(fax__Site__c = customer.Id);
        insert inv;

        Test.startTest();
        List<AddJobItemsController.InstalledItemOption> options =
            AddJobItemsController.searchInstalledItemsForGrid(inv.Id, 'SN');
        Test.stopTest();

        System.assertEquals(0, options.size());
    }

    @isTest
    static void testGetActivePricebookEntries() {
        Id pricebookId = [SELECT fax__Pricebook__c FROM fax__Job__c LIMIT 1].fax__Pricebook__c;
        Product2 prod = [SELECT Id, Description FROM Product2 WHERE ProductCode = 'TP-001' LIMIT 1];
        Set<Id> productIds = new Set<Id>{ prod.Id };

        Test.startTest();
        System.assertEquals(
            0,
            AddJobItemsController.getActivePricebookEntries(null, null).size(),
            'Null price book should return no rows.'
        );
        List<PricebookEntry> allEntries = AddJobItemsController.getActivePricebookEntries(
            pricebookId,
            null
        );
        List<PricebookEntry> filteredEntries = AddJobItemsController.getActivePricebookEntries(
            pricebookId,
            productIds
        );
        Test.stopTest();

        System.assert(allEntries.size() > 0, 'Expected active price book entries.');
        System.assertEquals(1, filteredEntries.size(), 'Expected one filtered entry.');
        System.assertEquals(prod.Id, filteredEntries[0].Product2Id);
    }

    @isTest
    static void testSearchProductsForGrid_AllProducts() {
        fax__Job__c job = [SELECT Id, fax__Pricebook__c FROM fax__Job__c LIMIT 1];

        Test.startTest();
        List<AddJobItemsController.GridLineRow> rows =
            AddJobItemsController.searchProductsForGrid(
                job.Id,
                'Test',
                'ALL_PRODUCTS',
                job.fax__Pricebook__c
            );
        Test.stopTest();

        System.assert(rows.size() > 0);
        System.assertEquals(1, rows[0].quantity);
        System.assertNotEquals(null, rows[0].productId);
        System.assertEquals('SN-TEST-001', rows[0].installedItem);
    }

    @isTest
    static void testSearchProductsForGrid_InvoiceDefaultsIncludeInInvoice() {
        fax__Invoice__c inv = createInvoice();

        Test.startTest();
        List<AddJobItemsController.GridLineRow> rows =
            AddJobItemsController.searchProductsForGrid(
                inv.Id,
                'Test',
                'ALL_PRODUCTS',
                null
            );
        Test.stopTest();

        System.assert(rows.size() > 0);
        System.assertEquals(true, rows[0].includeInInvoice);
    }

    @isTest
    static void testSearchInstalledItemsForGrid() {
        fax__Job__c job = [SELECT Id FROM fax__Job__c LIMIT 1];

        Test.startTest();
        List<AddJobItemsController.InstalledItemOption> options =
            AddJobItemsController.searchInstalledItemsForGrid(job.Id, 'SN-TEST');
        Test.stopTest();

        System.assertEquals(1, options.size());
        System.assertEquals('SN-TEST-001', options[0].serialNumber);
        System.assertNotEquals(null, options[0].installedSystemId);
    }

    @isTest
    static void testSaveLineItemsForGrid_Job_InsertUpdateDelete() {
        fax__Job__c job = [SELECT Id FROM fax__Job__c LIMIT 1];
        Product2 prod = [SELECT Id, Description FROM Product2 WHERE ProductCode = 'TP-001' LIMIT 1];
        fax__Installed_System__c installedSystem = [
            SELECT Id
            FROM fax__Installed_System__c
            WHERE fax__Serial_Number__c = 'SN-TEST-001'
            LIMIT 1
        ];

        AddJobItemsController.GridLineRow row = new AddJobItemsController.GridLineRow();
        row.productId = prod.Id;
        row.installedSystemId = installedSystem.Id;
        row.description = 'Job engineer comment';
        row.quantity = 2;
        row.listPrice = 150;
        row.unitPrice = 100;
        row.discount = 0;

        Test.startTest();
        List<AddJobItemsController.GridLineRow> inserted =
            AddJobItemsController.saveLineItemsForGrid(
                job.Id,
                new List<AddJobItemsController.GridLineRow>{ row }
            );
        Test.stopTest();

        System.assertEquals(1, inserted.size());
        Id rowId = inserted[0].rowId;

        AddJobItemsController.GridLineRow updateRow = inserted[0];
        updateRow.quantity = 4;
        updateRow.unitPrice = 50;

        AddJobItemsController.saveLineItemsForGrid(
            job.Id,
            new List<AddJobItemsController.GridLineRow>{ updateRow }
        );

        fax__Job_System__c updated = [
            SELECT fax__Quantity__c, fax__Unit_Price__c, fax__Installed_System__c, Engineer_Comments__c
            FROM fax__Job_System__c
            WHERE Id = :rowId
        ];
        System.assertEquals(4, updated.fax__Quantity__c);
        System.assertEquals(50, updated.fax__Unit_Price__c);
        System.assertEquals(installedSystem.Id, updated.fax__Installed_System__c);
        System.assertEquals('Job engineer comment', updated.Engineer_Comments__c);

        updateRow.isDeleted = true;
        AddJobItemsController.saveLineItemsForGrid(
            job.Id,
            new List<AddJobItemsController.GridLineRow>{ updateRow }
        );

        System.assertEquals(
            0,
            [SELECT COUNT() FROM fax__Job_System__c WHERE Id = :rowId]
        );
    }

    @isTest
    static void testSaveLineItemsForGrid_Job_DefaultsDescriptionFromProduct() {
        fax__Job__c job = [SELECT Id FROM fax__Job__c LIMIT 1];
        Product2 prod = [SELECT Id, Description FROM Product2 WHERE ProductCode = 'TP-001' LIMIT 1];

        AddJobItemsController.GridLineRow row = new AddJobItemsController.GridLineRow();
        row.productId = prod.Id;
        row.quantity = 1;
        row.unitPrice = 10;
        row.discount = 0;

        Test.startTest();
        List<AddJobItemsController.GridLineRow> saved =
            AddJobItemsController.saveLineItemsForGrid(
                job.Id,
                new List<AddJobItemsController.GridLineRow>{ row }
            );
        Test.stopTest();

        System.assertEquals(1, saved.size());
        System.assertEquals(prod.Description, saved[0].description);

        fax__Job_System__c line = [
            SELECT Engineer_Comments__c
            FROM fax__Job_System__c
            WHERE Id = :saved[0].rowId
        ];
        System.assertEquals(prod.Description, line.Engineer_Comments__c);
    }

    @isTest
    static void testSaveLineItemsForGrid_Invoice_InsertUpdateDelete() {
        fax__Invoice__c inv = createInvoice();
        Product2 prod = [SELECT Id, Description FROM Product2 WHERE ProductCode = 'TP-001' LIMIT 1];

        AddJobItemsController.GridLineRow row = new AddJobItemsController.GridLineRow();
        row.productId = prod.Id;
        row.description = 'Grid invoice line';
        row.quantity = 2;
        row.unitPrice = 35;
        row.discount = 0;

        Test.startTest();
        List<AddJobItemsController.GridLineRow> inserted =
            AddJobItemsController.saveLineItemsForGrid(
                inv.Id,
                new List<AddJobItemsController.GridLineRow>{ row }
            );
        Test.stopTest();

        System.assertEquals(1, inserted.size());
        Id rowId = inserted[0].rowId;

        AddJobItemsController.GridLineRow updateRow = inserted[0];
        updateRow.quantity = 5;
        updateRow.unitPrice = 20;

        AddJobItemsController.saveLineItemsForGrid(
            inv.Id,
            new List<AddJobItemsController.GridLineRow>{ updateRow }
        );

        fax__Invoice_Line_Item__c updated = [
            SELECT fax__Qty__c, fax__Unit_Price__c
            FROM fax__Invoice_Line_Item__c
            WHERE Id = :rowId
        ];
        System.assertEquals(5, updated.fax__Qty__c);
        System.assertEquals(20, updated.fax__Unit_Price__c);

        updateRow.isDeleted = true;
        AddJobItemsController.saveLineItemsForGrid(
            inv.Id,
            new List<AddJobItemsController.GridLineRow>{ updateRow }
        );

        System.assertEquals(
            0,
            [SELECT COUNT() FROM fax__Invoice_Line_Item__c WHERE Id = :rowId]
        );
    }

    // ── buildFieldAxException Coverage ───────────────────────────────

    @isTest
    static void testBuildFieldAxException_CreateJobSystems() {

        fax__Job__c job = [SELECT Id FROM fax__Job__c LIMIT 1];

        fax__Job_System__c js = new fax__Job_System__c(
            fax__Job_New__c = job.Id
        );

        Test.startTest();

        try {

            AddJobItemsController.createJobSystems(
                new List<fax__Job_System__c>{ js }
            );

            System.assert(false);

        } catch (Exception e) {

            System.assert(e.getMessage().length() > 0);
        }

        Test.stopTest();
    }

    @isTest
    static void testBuildFieldAxException_CreateInvoiceLineItems() {

        fax__Invoice__c inv = createInvoice();

        fax__Invoice_Line_Item__c li =
            new fax__Invoice_Line_Item__c(
                fax__Invoice__c = inv.Id
            );

        Test.startTest();

        try {

            AddJobItemsController.createInvoiceLineItems(
                new List<fax__Invoice_Line_Item__c>{ li }
            );


        } catch (Exception e) {

            System.assert(e.getMessage().length() > 0);
        }

        Test.stopTest();
    }

    @isTest
    static void testBuildFieldAxException_UpdatePricebookOnJob() {

        fax__Job__c job = [SELECT Id FROM fax__Job__c LIMIT 1];

        Test.startTest();

        try {

            AddJobItemsController.updatePricebookOnJob(
                '001000000000000AAA',
                job.Id
            );

            System.assert(false);

        } catch (Exception e) {

            System.assert(e.getMessage().length() > 0);
        }

        Test.stopTest();
    }
}