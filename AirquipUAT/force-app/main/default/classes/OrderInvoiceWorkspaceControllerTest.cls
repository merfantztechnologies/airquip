@IsTest
private class OrderInvoiceWorkspaceControllerTest {
    @TestSetup
    static void setupData() {
        Account account = new Account(
            Name = 'Direct Invoice Account',
            BillingStreet = '100 Main St',
            BillingCity = 'Austin',
            BillingCountryCode = 'US',
            BillingStateCode = 'TX',
            BillingPostalCode = '78701',
            ShippingStreet = '200 Ship St',
            ShippingCity = 'Austin',
            ShippingCountryCode = 'US',
            ShippingStateCode = 'TX',
            ShippingPostalCode = '78701'
        );
        insert account;

        Contact contact = new Contact(
            FirstName = 'Invoice',
            LastName = 'Contact',
            Email = 'invoice.contact@example.com',
            AccountId = account.Id
        );
        insert contact;

        Id standardPricebookId = Test.getStandardPricebookId();
        update new Pricebook2(Id = standardPricebookId, IsActive = true);

        Product2 nonInstalledProduct = new Product2(
            Name = 'Non Installed Product',
            ProductCode = 'NIP-001',
            Description = 'Non-installed product line',
            Family = 'Hardware',
            IsActive = true,
            Is_Installed_System__c = false,
            Is_Taxable__c = true
        );
        Product2 installedProduct = new Product2(
            Name = 'Installed Product',
            ProductCode = 'INS-001',
            Family = 'Hardware',
            IsActive = true,
            Is_Installed_System__c = true,
            Is_Taxable__c = true
        );
        insert new List<Product2>{ nonInstalledProduct, installedProduct };

        insert new List<PricebookEntry>{
            new PricebookEntry(
                Pricebook2Id = standardPricebookId,
                Product2Id = nonInstalledProduct.Id,
                UnitPrice = 125,
                IsActive = true
            ),
            new PricebookEntry(
                Pricebook2Id = standardPricebookId,
                Product2Id = installedProduct.Id,
                UnitPrice = 250,
                IsActive = true
            )
        };

        Order orderRecord = new Order(
            AccountId = account.Id,
            Contact__c = contact.Id,
            EffectiveDate = Date.today(),
            Status = getOrderStatusForTest(),
            Pricebook2Id = standardPricebookId,
            PoNumber = 'PO-1001',
            Payment_Terms__c = 'NET 30',
            BillingStreet = '200 Billing St',
            BillingCity = 'Dallas',
            BillingCountryCode = 'US',
            BillingStateCode = 'TX',
            BillingPostalCode = '75001'
        );
        insert orderRecord;

        Map<Id, PricebookEntry> pbesByProduct = new Map<Id, PricebookEntry>();
        for (PricebookEntry pbe : [
            SELECT Id, Product2Id
            FROM PricebookEntry
            WHERE Product2Id IN :new Set<Id>{ nonInstalledProduct.Id, installedProduct.Id }
        ]) {
            pbesByProduct.put(pbe.Product2Id, pbe);
        }

        insert new List<OrderItem>{
            new OrderItem(
                OrderId = orderRecord.Id,
                PricebookEntryId = pbesByProduct.get(nonInstalledProduct.Id).Id,
                Quantity = 2,
                UnitPrice = 125,
                Description = 'Order non-installed description'
            ),
            new OrderItem(
                OrderId = orderRecord.Id,
                PricebookEntryId = pbesByProduct.get(installedProduct.Id).Id,
                Quantity = 1,
                UnitPrice = 250,
                Description = 'Installed item should be excluded'
            )
        };
    }

    @IsTest
    static void getWorkspaceLoadsOnlyNonInstalledLines() {
        Order orderRecord = [SELECT Id FROM Order LIMIT 1];

        Test.startTest();
        OrderInvoiceService.Workspace workspace =
            OrderInvoiceWorkspaceController.getWorkspace(orderRecord.Id);
        Test.stopTest();

        System.assertEquals(orderRecord.Id, workspace.orderId);
        System.assertEquals(1, workspace.lines.size(), 'Installed products should not load into direct invoice lines.');
        System.assertEquals('Non Installed Product', workspace.lines[0].productName);
        System.assertEquals(250, workspace.subtotal);
        System.assertEquals(250, workspace.amountDue);
        System.assertNotEquals(null, workspace.eligibilityMessage);
    }

    @IsTest
    static void createDraftInvoiceCreatesHeaderAndLinesOnly() {
        Order orderRecord = [SELECT Id FROM Order LIMIT 1];
        OrderInvoiceService.Workspace workspace =
            OrderInvoiceWorkspaceController.getWorkspace(orderRecord.Id);

        OrderInvoiceService.SaveRequest request = new OrderInvoiceService.SaveRequest();
        request.orderId = workspace.orderId;
        request.accountId = workspace.accountId;
        request.contactId = workspace.contactId;
        request.ownerId = workspace.ownerId;
        request.transactionDate = Date.today();
        request.dueDate = Date.today().addDays(30);
        request.poNumber = workspace.poNumber;
        request.terms = 'NET 30';
        request.jobCategory = getJobCategoryForTest();
        request.billingStreet = workspace.billingStreet;
        request.billingCity = workspace.billingCity;
        request.billingState = workspace.billingState;
        request.billingPostalCode = workspace.billingPostalCode;
        request.jobDescription = 'Direct invoice without job';
        request.jobDetail = 'Created from Order quick action';
        request.engineerCompletionNotes = 'No installation workflow required';
        request.syncToQuickBooks = true;
        request.sendToQuickBooks = false;
        request.lines = workspace.lines;

        Test.startTest();
        OrderInvoiceService.SaveResult result =
            OrderInvoiceWorkspaceController.createDraftInvoice(request);
        Test.stopTest();

        fax__Invoice__c invoiceRecord = [
            SELECT Id, Order__c, fax__Site__c, fax__Contact__c, fax__Status__c, fax__PO_Number__c,
                   fax__Terms__c, fax__Street__c, fax__City__c, fax__State__c,
                   fax__Postal_Code__c, Job_Description__c, Job_Detail__c,
                   Engineer_Completion_Notes__c, Sync_to_Quickbooks__c, Send_to_QuickBooks__c
            FROM fax__Invoice__c
            WHERE Id = :result.invoiceId
        ];
        System.assertEquals(orderRecord.Id, invoiceRecord.Order__c, 'Invoice should reference the source Order.');
        System.assertEquals(workspace.accountId, invoiceRecord.fax__Site__c);
        System.assertEquals(workspace.contactId, invoiceRecord.fax__Contact__c);
        System.assertEquals('Draft', invoiceRecord.fax__Status__c);
        System.assertEquals('PO-1001', invoiceRecord.fax__PO_Number__c);
        System.assertEquals('Direct invoice without job', invoiceRecord.Job_Description__c);
        System.assertEquals(true, invoiceRecord.Sync_to_Quickbooks__c);
        System.assertEquals(false, invoiceRecord.Send_to_QuickBooks__c);

        List<fax__Invoice_Line_Item__c> lines = [
            SELECT fax__Invoice__c, fax__Product__r.Name, fax__Qty__c, fax__Unit_Price__c,
                   Description__c, Include_In_Invoice__c
            FROM fax__Invoice_Line_Item__c
            WHERE fax__Invoice__c = :result.invoiceId
        ];
        System.assertEquals(1, lines.size());
        System.assertEquals('Non Installed Product', lines[0].fax__Product__r.Name);
        System.assertEquals(2, lines[0].fax__Qty__c);
        System.assertEquals(125, lines[0].fax__Unit_Price__c);
        System.assertEquals('Order non-installed description', lines[0].Description__c);
        System.assertEquals(true, lines[0].Include_In_Invoice__c);
    }

    @IsTest
    static void searchStandardProductsExcludesInstalledProducts() {
        Test.startTest();
        List<OrderInvoiceService.ProductOption> products =
            OrderInvoiceWorkspaceController.searchStandardProducts('Product');
        Test.stopTest();

        System.assertEquals(1, products.size());
        System.assertEquals('Non Installed Product', products[0].productName);
        System.assertEquals(125, products[0].unitPrice);
    }

    @IsTest
    static void searchStandardProductsReturnsResultsForBlankTerm() {
        List<OrderInvoiceService.ProductOption> products =
            OrderInvoiceWorkspaceController.searchStandardProducts('');

        System.assertEquals(1, products.size());
        System.assertEquals('Non Installed Product', products[0].productName);
    }

    @IsTest
    static void createDraftInvoiceSkipsOrderLookupWhenOrderIdMissing() {
        Order orderRecord = [SELECT Id FROM Order LIMIT 1];
        OrderInvoiceService.Workspace workspace =
            OrderInvoiceWorkspaceController.getWorkspace(orderRecord.Id);

        OrderInvoiceService.SaveRequest request = buildSaveRequest(workspace);
        request.orderId = null;

        Test.startTest();
        OrderInvoiceService.SaveResult result =
            OrderInvoiceWorkspaceController.createDraftInvoice(request);
        Test.stopTest();

        fax__Invoice__c invoiceRecord = [
            SELECT Order__c
            FROM fax__Invoice__c
            WHERE Id = :result.invoiceId
        ];
        System.assertEquals(null, invoiceRecord.Order__c, 'Missing Order Id should not block invoice creation.');
    }

    @IsTest
    static void createDraftInvoiceValidatesRequiredLines() {
        OrderInvoiceService.SaveRequest request = new OrderInvoiceService.SaveRequest();
        request.accountId = [SELECT Id FROM Account LIMIT 1].Id;
        request.lines = new List<OrderInvoiceService.LineItem>();

        try {
            OrderInvoiceWorkspaceController.createDraftInvoice(request);
            System.assert(false, 'Expected validation failure.');
        } catch (AuraHandledException e) {
            System.assert(true, 'Validation exception expected.');
        }
    }

    @IsTest
    static void getWorkspaceRequiresOrderId() {
        try {
            OrderInvoiceWorkspaceController.getWorkspace(null);
            System.assert(false, 'Expected missing Order Id failure.');
        } catch (AuraHandledException e) {
            System.assert(true, 'Missing Order Id exception expected.');
        }
    }

    @IsTest
    static void getWorkspaceHandlesGenericException() {
        // Use a dummy Order ID that doesn't exist in the database to trigger QueryException
        Id dummyOrderId = '801000000000000AAA';
        Test.startTest();
        try {
            OrderInvoiceWorkspaceController.getWorkspace(dummyOrderId);
            System.assert(false, 'Expected AuraHandledException due to QueryException');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void getInvoiceStatusValuesTest() {
        Test.startTest();
        List<String> statusValues = OrderInvoiceWorkspaceController.getInvoiceStatusValues();
        Test.stopTest();
        System.assertNotEquals(null, statusValues);
        System.assert(!statusValues.isEmpty());
    }

    @IsTest
    static void getInvoiceClassValuesTest() {
        Test.startTest();
        List<String> classValues = OrderInvoiceWorkspaceController.getInvoiceClassValues();
        Test.stopTest();
        System.assertNotEquals(null, classValues);
    }

    @IsTest
    static void getInvoiceJobCategoryValuesTest() {
        Test.startTest();
        List<String> jobCategoryValues = OrderInvoiceWorkspaceController.getInvoiceJobCategoryValues();
        Test.stopTest();
        System.assertNotEquals(null, jobCategoryValues);
        System.assert(!jobCategoryValues.isEmpty());
    }

    @IsTest
    static void getInvoiceTermsValuesTest() {
        Test.startTest();
        List<String> termsValues = OrderInvoiceWorkspaceController.getInvoiceTermsValues();
        Test.stopTest();
        System.assertNotEquals(null, termsValues);
        System.assert(!termsValues.isEmpty());
    }

    @IsTest
    static void getAccountContactsSuccessTest() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Test.startTest();
        List<Contact> contacts = OrderInvoiceWorkspaceController.getAccountContacts(acc.Id);
        Test.stopTest();
        System.assertNotEquals(null, contacts);
        System.assertEquals(1, contacts.size());
    }

    @IsTest
    static void getAccountContactsFailureTest() {
        Test.startTest();
        try {
            OrderInvoiceWorkspaceController.getAccountContacts(null);
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void createDraftInvoiceHandlesGenericException() {
        Test.startTest();
        try {
            OrderInvoiceWorkspaceController.createDraftInvoice(null);
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    private static String getOrderStatusForTest() {
        for (Schema.PicklistEntry entry : Order.Status.getDescribe().getPicklistValues()) {
            if (entry.isActive() && entry.getValue() == 'Approved') {
                return 'Approved';
            }
        }
        for (Schema.PicklistEntry entry : Order.Status.getDescribe().getPicklistValues()) {
            if (entry.isActive()) {
                return entry.getValue();
            }
        }
        return 'Draft';
    }

    private static String getJobCategoryForTest() {
        for (Schema.PicklistEntry entry : fax__Invoice__c.Job_Category__c.getDescribe().getPicklistValues()) {
            if (entry.isActive()) {
                return entry.getValue();
            }
        }
        return 'General';
    }

    private static OrderInvoiceService.SaveRequest buildSaveRequest(OrderInvoiceService.Workspace workspace) {
        OrderInvoiceService.SaveRequest request = new OrderInvoiceService.SaveRequest();
        request.orderId = workspace.orderId;
        request.accountId = workspace.accountId;
        request.contactId = workspace.contactId;
        request.ownerId = workspace.ownerId;
        request.transactionDate = Date.today();
        request.dueDate = Date.today().addDays(30);
        request.poNumber = workspace.poNumber;
        request.terms = 'NET 30';
        request.jobCategory = getJobCategoryForTest();
        request.billingStreet = workspace.billingStreet;
        request.billingCity = workspace.billingCity;
        request.billingState = workspace.billingState;
        request.billingPostalCode = workspace.billingPostalCode;
        request.jobDescription = 'Direct invoice without job';
        request.jobDetail = 'Created from Order quick action';
        request.engineerCompletionNotes = 'No installation workflow required';
        request.syncToQuickBooks = true;
        request.sendToQuickBooks = false;
        request.lines = workspace.lines;
        return request;
    }
}