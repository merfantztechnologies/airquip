@IsTest
private class OrderInvoiceServiceTest {

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
                Description = 'Order non-installed description',
                Line_Description__c = 'Custom Line Description'
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

    @IsTest
    static void testGetWorkspaceSuccess() {
        Order orderRecord = [SELECT Id FROM Order LIMIT 1];

        Test.startTest();
        OrderInvoiceService.Workspace workspace = OrderInvoiceService.getWorkspace(orderRecord.Id);
        Test.stopTest();

        System.assertNotEquals(null, workspace);
        System.assertEquals(orderRecord.Id, workspace.orderId);
        System.assertEquals(1, workspace.lines.size());
        System.assertEquals('Custom Line Description', workspace.lines[0].description);
        System.assertEquals(250.00, workspace.subtotal);
        System.assertEquals(250.00, workspace.grandTotal);
    }

    @IsTest
    static void testGetWorkspaceNullOrderId() {
        Test.startTest();
        try {
            OrderInvoiceService.getWorkspace(null);
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void testGetWorkspaceQueryException() {
        // Use a dummy non-existent Order ID to trigger a QueryException
        Id dummyOrderId = '801000000000000AAA';
        Test.startTest();
        try {
            OrderInvoiceService.getWorkspace(dummyOrderId);
            System.assert(false, 'Expected QueryException');
        } catch (Exception e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void testCalculateDueDateBranches() {
        Order orderRecord = [SELECT Id FROM Order LIMIT 1];
        
        // We will test various payment terms values by calling the workspace loader or creating requests
        // since calculateDueDate is private, we cover it through getWorkspace by updating Order terms
        
        // 1. null terms
        orderRecord.Payment_Terms__c = null;
        update orderRecord;
        OrderInvoiceService.Workspace workspaceNull = OrderInvoiceService.getWorkspace(orderRecord.Id);
        System.assertEquals(Date.today().addDays(30), workspaceNull.dueDate);

        // 2. Receipt terms
        orderRecord.Payment_Terms__c = 'Due on Receipt';
        update orderRecord;
        OrderInvoiceService.Workspace workspaceReceipt = OrderInvoiceService.getWorkspace(orderRecord.Id);
        System.assertEquals(Date.today(), workspaceReceipt.dueDate);

        // 3. Digital terms (NET 45)
        orderRecord.Payment_Terms__c = 'NET 45';
        update orderRecord;
        OrderInvoiceService.Workspace workspaceNet45 = OrderInvoiceService.getWorkspace(orderRecord.Id);
        System.assertEquals(Date.today().addDays(45), workspaceNet45.dueDate);

        // 4. Terms with no digits (COD)
        orderRecord.Payment_Terms__c = 'COD';
        update orderRecord;
        OrderInvoiceService.Workspace workspaceCod = OrderInvoiceService.getWorkspace(orderRecord.Id);
        System.assertEquals(Date.today().addDays(30), workspaceCod.dueDate);
    }

    @IsTest
    static void testSearchStandardProductsSuccess() {
        Test.startTest();
        List<OrderInvoiceService.ProductOption> optionsTerm = OrderInvoiceService.searchStandardProducts('Non Installed');
        List<OrderInvoiceService.ProductOption> optionsBlank = OrderInvoiceService.searchStandardProducts('');
        List<OrderInvoiceService.ProductOption> optionsNull = OrderInvoiceService.searchStandardProducts(null);
        Test.stopTest();

        System.assert(optionsTerm.size() > 0);
        System.assertEquals('Non Installed Product', optionsTerm[0].productName);
        System.assert(optionsBlank.size() > 0);
        System.assert(optionsNull.size() > 0);
    }

    @IsTest
    static void testCreateDraftInvoiceSuccess() {
        Order orderRecord = [SELECT Id FROM Order LIMIT 1];
        OrderInvoiceService.Workspace workspace = OrderInvoiceService.getWorkspace(orderRecord.Id);

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
        request.jobDescription = 'Direct invoice test description';
        request.jobDetail = 'Test detail';
        request.engineerCompletionNotes = 'Test notes';
        request.syncToQuickBooks = true;
        request.sendToQuickBooks = false;
        request.lines = workspace.lines;

        Test.startTest();
        OrderInvoiceService.SaveResult result = OrderInvoiceService.createDraftInvoice(request);
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertNotEquals(null, result.invoiceId);

        fax__Invoice__c inv = [SELECT Id, Order__c, fax__Status__c FROM fax__Invoice__c WHERE Id = :result.invoiceId];
        System.assertEquals(orderRecord.Id, inv.Order__c);
        System.assertEquals('Draft', inv.fax__Status__c);
    }

    @IsTest
    static void testCreateDraftInvoiceValidationFailures() {
        Order orderRecord = [SELECT Id FROM Order LIMIT 1];
        OrderInvoiceService.Workspace workspace = OrderInvoiceService.getWorkspace(orderRecord.Id);

        // 1. Null Request
        try {
            OrderInvoiceService.createDraftInvoice(null);
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(true);
        }

        // 2. Null AccountId
        OrderInvoiceService.SaveRequest req = new OrderInvoiceService.SaveRequest();
        try {
            OrderInvoiceService.createDraftInvoice(req);
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(true);
        }

        // 3. Blank Job Category
        req.accountId = workspace.accountId;
        req.jobCategory = '';
        try {
            OrderInvoiceService.createDraftInvoice(req);
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(true);
        }

        // 4. Null/Empty Lines
        req.jobCategory = getJobCategoryForTest();
        req.lines = null;
        try {
            OrderInvoiceService.createDraftInvoice(req);
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(true);
        }

        req.lines = new List<OrderInvoiceService.LineItem>();
        try {
            OrderInvoiceService.createDraftInvoice(req);
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(true);
        }

        // 5. Only Deleted Lines
        OrderInvoiceService.LineItem delItem = new OrderInvoiceService.LineItem();
        delItem.isDeleted = true;
        req.lines.add(delItem);
        try {
            OrderInvoiceService.createDraftInvoice(req);
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(true);
        }

        // 6. Null Product ID in line
        OrderInvoiceService.LineItem line = new OrderInvoiceService.LineItem();
        line.isDeleted = false;
        line.productId = null;
        req.lines.clear();
        req.lines.add(line);
        try {
            OrderInvoiceService.createDraftInvoice(req);
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(true);
        }

        // 7. Invalid Quantity
        line.productId = workspace.lines[0].productId;
        line.quantity = null;
        try {
            OrderInvoiceService.createDraftInvoice(req);
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(true);
        }

        line.quantity = -5;
        try {
            OrderInvoiceService.createDraftInvoice(req);
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(true);
        }

        // 8. Invalid Unit Price
        line.quantity = 2;
        line.unitPrice = null;
        try {
            OrderInvoiceService.createDraftInvoice(req);
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(true);
        }

        line.unitPrice = -10;
        try {
            OrderInvoiceService.createDraftInvoice(req);
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
    }

    @IsTest
    static void testCreateDraftInvoiceDmlFailure() {
        Order orderRecord = [SELECT Id FROM Order LIMIT 1];
        OrderInvoiceService.Workspace workspace = OrderInvoiceService.getWorkspace(orderRecord.Id);

        OrderInvoiceService.SaveRequest request = new OrderInvoiceService.SaveRequest();
        request.accountId = workspace.accountId;
        request.jobCategory = getJobCategoryForTest();
        
        // Pass a line item with a non-existent product ID (causes lookup/DML failure on insert of line item)
        OrderInvoiceService.LineItem badLine = new OrderInvoiceService.LineItem();
        badLine.productId = '01t000000000000AAA';
        badLine.quantity = 1;
        badLine.unitPrice = 100;
        badLine.isDeleted = false;
        
        request.lines = new List<OrderInvoiceService.LineItem>{ badLine };

        Test.startTest();
        try {
            OrderInvoiceService.createDraftInvoice(request);
            System.assert(false, 'Expected AuraHandledException due to DML failure');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null);
        }
        Test.stopTest();
    }

    @IsTest
    static void testSearchStandardProductsInactivePricebook() {
        // Deactivate the standard pricebook
        update new Pricebook2(Id = Test.getStandardPricebookId(), IsActive = false);

        Test.startTest();
        try {
            OrderInvoiceService.searchStandardProducts('Non Installed');
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void testCreateDraftInvoiceWithDeletedLines() {
        Order orderRecord = [SELECT Id FROM Order LIMIT 1];
        OrderInvoiceService.Workspace workspace = OrderInvoiceService.getWorkspace(orderRecord.Id);

        OrderInvoiceService.SaveRequest request = new OrderInvoiceService.SaveRequest();
        request.accountId = workspace.accountId;
        request.jobCategory = getJobCategoryForTest();
        
        // Add one active line and one deleted line to test line continuation (line 231 continue branch)
        OrderInvoiceService.LineItem activeLine = workspace.lines[0];
        
        OrderInvoiceService.LineItem deletedLine = new OrderInvoiceService.LineItem();
        deletedLine.productId = activeLine.productId;
        deletedLine.quantity = 1;
        deletedLine.unitPrice = 10;
        deletedLine.isDeleted = true;

        request.lines = new List<OrderInvoiceService.LineItem>{ activeLine, deletedLine };

        Test.startTest();
        OrderInvoiceService.SaveResult result = OrderInvoiceService.createDraftInvoice(request);
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertNotEquals(null, result.invoiceId);
        
        // Confirm only 1 line item is inserted
        List<fax__Invoice_Line_Item__c> lines = [
            SELECT Id FROM fax__Invoice_Line_Item__c WHERE fax__Invoice__c = :result.invoiceId
        ];
        System.assertEquals(1, lines.size());
    }

    @IsTest
    static void testEligibilityOnlyInstalledProducts() {
        Account account = [SELECT Id FROM Account LIMIT 1];
        Contact contact = [SELECT Id FROM Contact LIMIT 1];
        Id standardPricebookId = Test.getStandardPricebookId();

        // Create an Order that ONLY has an installed product
        Order orderRecord = new Order(
            AccountId = account.Id,
            Contact__c = contact.Id,
            EffectiveDate = Date.today(),
            Status = getOrderStatusForTest(),
            Pricebook2Id = standardPricebookId
        );
        insert orderRecord;

        Product2 installedProduct = [SELECT Id FROM Product2 WHERE Is_Installed_System__c = true LIMIT 1];
        PricebookEntry pbe = [SELECT Id FROM PricebookEntry WHERE Product2Id = :installedProduct.Id LIMIT 1];

        insert new OrderItem(
            OrderId = orderRecord.Id,
            PricebookEntryId = pbe.Id,
            Quantity = 1,
            UnitPrice = 250
        );

        Test.startTest();
        OrderInvoiceService.Workspace workspace = OrderInvoiceService.getWorkspace(orderRecord.Id);
        Test.stopTest();

        System.assertEquals(false, workspace.eligible);
        System.assert(workspace.eligibilityMessage.contains('Order must contain at least one non-installed product.'));
    }

    @IsTest
    static void testCreateDraftInvoiceInvalidOrderSObjectType() {
        Order orderRecord = [SELECT Id FROM Order LIMIT 1];
        OrderInvoiceService.Workspace workspace = OrderInvoiceService.getWorkspace(orderRecord.Id);

        OrderInvoiceService.SaveRequest request = new OrderInvoiceService.SaveRequest();
        request.accountId = workspace.accountId;
        request.jobCategory = getJobCategoryForTest();
        request.lines = workspace.lines;
        
        // Pass Account ID instead of Order ID to trigger SObjectType check failure in resolveOrderId (line 407)
        request.orderId = workspace.accountId;

        Test.startTest();
        OrderInvoiceService.SaveResult result = OrderInvoiceService.createDraftInvoice(request);
        Test.stopTest();

        System.assertNotEquals(null, result);
        fax__Invoice__c inv = [SELECT Id, Order__c FROM fax__Invoice__c WHERE Id = :result.invoiceId];
        System.assertEquals(null, inv.Order__c);
    }

    @IsTest
    static void testEligibilityRestrictedUser() {
        Order orderRecord = [SELECT Id FROM Order LIMIT 1];
        
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1];
        User restrictedUser = new User(
            Alias = 'restUser',
            Email = 'restricteduser@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'Testing',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            TimeZoneSidKey = 'America/Los_Angeles',
            UserName = 'restricteduser_' + DateTime.now().getTime() + '@example.com'
        );
        insert restrictedUser;

        Test.startTest();
        OrderInvoiceService.Workspace workspace;
        System.runAs(restrictedUser) {
            workspace = OrderInvoiceService.getWorkspace(orderRecord.Id);
        }
        Test.stopTest();

        System.assertEquals(false, workspace.eligible);
        System.assert(workspace.eligibilityMessage.contains('permission'));
    }

    @IsTest
    static void testGetWorkspaceForAccount() {
        Account account = [SELECT Id FROM Account LIMIT 1];
        account.Terms__c = 'NET 45';
        update account;

        Contact contact = [SELECT Id FROM Contact LIMIT 1];

        Test.startTest();
        OrderInvoiceService.Workspace workspace = OrderInvoiceService.getWorkspace(account.Id);
        Test.stopTest();

        System.assertNotEquals(null, workspace);
        System.assertEquals(null, workspace.orderId);
        System.assertEquals(account.Id, workspace.accountId);
        System.assertEquals(contact.Id, workspace.contactId);
        System.assertEquals('NET 45', workspace.terms);
        System.assertEquals('100 Main St', workspace.billingStreet);
        System.assertEquals('Austin', workspace.billingCity);
        System.assertEquals(0, workspace.lines.size(), 'Lines should be empty initially');
        System.assertEquals(true, workspace.eligible);
    }
}