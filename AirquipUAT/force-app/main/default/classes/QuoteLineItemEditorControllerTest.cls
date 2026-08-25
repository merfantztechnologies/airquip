@IsTest
private class QuoteLineItemEditorControllerTest {
    @TestSetup
    static void setupData() {
        Account acc = new Account(
            Name = 'Test Account',
            BillingStreet = '100 Main St',
            BillingCity = 'Austin',
            BillingCountryCode = 'US',
            BillingStateCode = 'TX',
            BillingPostalCode = '78701',
            ShippingStreet = '100 Main St',
            ShippingCity = 'Austin',
            ShippingCountryCode = 'US',
            ShippingStateCode = 'TX',
            ShippingPostalCode = '78701'
        );
        insert acc;

        Opportunity opp = new Opportunity(
            Name = 'Test Opp',
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30),
            AccountId = acc.Id
        );
        insert opp;

        Id standardPricebookId = Test.getStandardPricebookId();

        Product2 prod = new Product2(
            Name = 'Test Product',
            ProductCode = 'TP-001',
            IsActive = true,
            Family = 'Hardware'
        );
        if (Schema.sObjectType.Product2.fields.getMap().containsKey('faxa__Purchase_Cost__c')) {
            prod.put('faxa__Purchase_Cost__c', 50.0);
        }
        insert prod;

        PricebookEntry pbe = new PricebookEntry(
            Pricebook2Id = standardPricebookId,
            Product2Id = prod.Id,
            UnitPrice = 100,
            IsActive = true
        );
        insert pbe;

        Quote q = new Quote(
            Name = 'Test Quote',
            OpportunityId = opp.Id,
            QuoteAccountId = acc.Id,
            Pricebook2Id = standardPricebookId
        );
        insert q;

        QuoteLineItem qli = new QuoteLineItem(
            QuoteId = q.Id,
            PricebookEntryId = pbe.Id,
            Quantity = 2,
            UnitPrice = 100,
            Cost__c = 50,
            Include_In_Quote__c = true
        );
        insert qli;
    }

    @IsTest
    static void getQuoteLineItemFieldOptionsTest() {
        Test.startTest();
        List<QuoteLineItemEditorController.QuoteLineItemFieldOption> options =
            QuoteLineItemEditorController.getQuoteLineItemFieldOptions();
        Test.stopTest();
        System.assertNotEquals(null, options);
    }

    @IsTest
    static void getQuoteLineItemsTest() {
        Quote q = [SELECT Id FROM Quote LIMIT 1];
        Test.startTest();
        List<QuoteLineItemEditorController.LineItemRow> rows =
            QuoteLineItemEditorController.getQuoteLineItems(q.Id, new List<String>{ 'ServiceDate' });
        Test.stopTest();
        System.assertEquals(1, rows.size());
        System.assertEquals(q.Id, [SELECT QuoteId FROM QuoteLineItem WHERE Id = :rows[0].quoteLineItemId].QuoteId);
    }

    @IsTest
    static void getQuoteLineItemsFailureTest() {
        Test.startTest();
        try {
            QuoteLineItemEditorController.getQuoteLineItems(null, null);
            System.assert(false, 'Expected exception');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void searchActiveProductsTest() {
        Quote q = [SELECT Id FROM Quote LIMIT 1];
        Test.startTest();
        List<QuoteLineItemEditorController.ProductOption> options =
            QuoteLineItemEditorController.searchActiveProducts(q.Id, 'Test');
        Test.stopTest();
        System.assertEquals(1, options.size());
    }

    @IsTest
    static void searchActiveProductsFailureTest() {
        Test.startTest();
        try {
            QuoteLineItemEditorController.searchActiveProducts(null, 'Test');
            System.assert(false, 'Expected exception');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void searchActiveProductsPrioritizesNameOverDescriptionTest() {
        Id standardPricebookId = Test.getStandardPricebookId();
        Quote q = [SELECT Id FROM Quote LIMIT 1];

        Product2 nameMatch = new Product2(
            Name = 'DESC Priority Product',
            ProductCode = 'DESC-PRI',
            Description = 'Unrelated text',
            IsActive = true,
            Family = 'Hardware'
        );
        Product2 descOnly = new Product2(
            Name = 'Classic Widget Alpha',
            ProductCode = 'CWA-001',
            Description = 'Description for desc-only product',
            IsActive = true,
            Family = 'Hardware'
        );
        insert new List<Product2>{ nameMatch, descOnly };

        insert new List<PricebookEntry>{
            new PricebookEntry(
                Pricebook2Id = standardPricebookId,
                Product2Id = nameMatch.Id,
                UnitPrice = 10,
                IsActive = true
            ),
            new PricebookEntry(
                Pricebook2Id = standardPricebookId,
                Product2Id = descOnly.Id,
                UnitPrice = 20,
                IsActive = true
            )
        };

        Test.startTest();
        List<QuoteLineItemEditorController.ProductOption> options =
            QuoteLineItemEditorController.searchActiveProducts(q.Id, 'desc');
        Test.stopTest();

        System.assert(options.size() >= 2, 'Expected name and description matches');
        System.assertEquals(
            'DESC Priority Product',
            options[0].productName,
            'Name or code matches should appear before description-only matches'
        );
    }

    @IsTest
    static void saveQuoteLineItemsTest() {
        Quote q = [SELECT Id FROM Quote LIMIT 1];
        PricebookEntry pbe = [SELECT Id FROM PricebookEntry LIMIT 1];
        QuoteLineItem qli = [SELECT Id FROM QuoteLineItem LIMIT 1];

        QuoteLineItemEditorController.SaveRequest req = new QuoteLineItemEditorController.SaveRequest();
        req.quoteId = q.Id;
        
        QuoteLineItemEditorController.LineItemRow row1 = new QuoteLineItemEditorController.LineItemRow();
        row1.quoteLineItemId = qli.Id;
        row1.pricebookEntryId = pbe.Id;
        row1.salesPrice = 90;
        row1.quantity = 3;
        row1.cost = 45;
        row1.includeInQuote = true;
        row1.lineItemDescription = 'Updated line';

        QuoteLineItemEditorController.LineItemRow row2 = new QuoteLineItemEditorController.LineItemRow();
        row2.pricebookEntryId = pbe.Id;
        row2.salesPrice = 120;
        row2.quantity = 1;
        row2.cost = 60;
        row2.includeInQuote = true;
        row2.lineItemDescription = 'New line';

        req.rows = new List<QuoteLineItemEditorController.LineItemRow>{ row1, row2 };
        req.deletedLineItemIds = new List<Id>();

        Test.startTest();
        QuoteLineItemEditorController.saveQuoteLineItems(req);
        Test.stopTest();

        List<QuoteLineItem> qlis = [SELECT Id, Quantity, UnitPrice, SortOrder FROM QuoteLineItem WHERE QuoteId = :q.Id ORDER BY SortOrder];
        System.assertEquals(2, qlis.size());
        System.assertEquals(3, qlis[0].Quantity);
        System.assertEquals(120, qlis[1].UnitPrice);
    }

    @IsTest
    static void saveQuoteLineItemsDeleteTest() {
        Quote q = [SELECT Id FROM Quote LIMIT 1];
        QuoteLineItem qli = [SELECT Id FROM QuoteLineItem LIMIT 1];

        QuoteLineItemEditorController.SaveRequest req = new QuoteLineItemEditorController.SaveRequest();
        req.quoteId = q.Id;
        req.rows = new List<QuoteLineItemEditorController.LineItemRow>();
        req.deletedLineItemIds = new List<Id>{ qli.Id };

        Test.startTest();
        QuoteLineItemEditorController.saveQuoteLineItems(req);
        Test.stopTest();

        List<QuoteLineItem> qlis = [SELECT Id FROM QuoteLineItem WHERE QuoteId = :q.Id];
        System.assertEquals(0, qlis.size());
    }

    @IsTest
    static void saveQuoteLineItemsValidationFailureTest() {
        Quote q = [SELECT Id FROM Quote LIMIT 1];
        PricebookEntry pbe = [SELECT Id FROM PricebookEntry LIMIT 1];

        QuoteLineItemEditorController.SaveRequest req = new QuoteLineItemEditorController.SaveRequest();
        req.quoteId = q.Id;
        
        QuoteLineItemEditorController.LineItemRow row = new QuoteLineItemEditorController.LineItemRow();
        row.pricebookEntryId = pbe.Id;
        row.salesPrice = -10; // Negative price
        row.quantity = 2;

        req.rows = new List<QuoteLineItemEditorController.LineItemRow>{ row };

        Test.startTest();
        try {
            QuoteLineItemEditorController.saveQuoteLineItems(req);
            System.assert(false, 'Expected validation exception');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void saveQuoteLineItemsWithNoPricebookTest() {
        Id stdPricebookId = Test.getStandardPricebookId();
        update new Pricebook2(Id = stdPricebookId, IsActive = true);

        Opportunity opp = [SELECT Id, AccountId FROM Opportunity LIMIT 1];
        PricebookEntry pbe = [SELECT Id FROM PricebookEntry LIMIT 1];

        Quote qNoPb = new Quote(
            Name = 'Test Quote No Pricebook',
            OpportunityId = opp.Id,
            QuoteAccountId = opp.AccountId
        );
        insert qNoPb;

        QuoteLineItemEditorController.SaveRequest req = new QuoteLineItemEditorController.SaveRequest();
        req.quoteId = qNoPb.Id;
        
        QuoteLineItemEditorController.LineItemRow row = new QuoteLineItemEditorController.LineItemRow();
        row.pricebookEntryId = pbe.Id;
        row.salesPrice = 150;
        row.quantity = 5;
        row.cost = 80;
        row.includeInQuote = true;
        row.lineItemDescription = 'Test no pricebook line';

        req.rows = new List<QuoteLineItemEditorController.LineItemRow>{ row };
        req.deletedLineItemIds = new List<Id>();

        Test.startTest();
        QuoteLineItemEditorController.saveQuoteLineItems(req);
        Test.stopTest();

        Quote updatedQuote = [SELECT Id, Pricebook2Id FROM Quote WHERE Id = :qNoPb.Id LIMIT 1];
        System.assertNotEquals(null, updatedQuote.Pricebook2Id, 'Quote Pricebook2Id should be populated');
        System.assertEquals(Test.getStandardPricebookId(), updatedQuote.Pricebook2Id, 'Quote Pricebook2Id should be standard pricebook');

        List<QuoteLineItem> qlis = [SELECT Id, Quantity, UnitPrice, PricebookEntryId FROM QuoteLineItem WHERE QuoteId = :qNoPb.Id];
        System.assertEquals(1, qlis.size(), 'QuoteLineItem should be saved');
        System.assertEquals(5, qlis[0].Quantity);
        System.assertEquals(150, qlis[0].UnitPrice);
        System.assertEquals(pbe.Id, qlis[0].PricebookEntryId);
    }
}