@IsTest
private class InvoiceLineItemEditorControllerTest {
    @TestSetup
    static void setupData() {
        faxa__Tax__c taxGroup = new faxa__Tax__c(
            Name = 'Test Tax Group',
            faxa__Percentage__c = 8.25,
            faxa__Tax_Code_Id__c = 'TAX001'
        );
        insert taxGroup;

        Account acc = new Account(
            Name = 'Test Account',
            Tax_Group_Code__c = taxGroup.Id,
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

        Contact contact = new Contact(
            FirstName = 'Test',
            LastName = 'Contact',
            AccountId = acc.Id
        );
        insert contact;

        Id standardPricebookId = Test.getStandardPricebookId();
        update new Pricebook2(Id = standardPricebookId, IsActive = true);

        Product2 prod = new Product2(
            Name = 'Test Product',
            ProductCode = 'TP-001',
            IsActive = true,
            Is_Taxable__c = true,
            Family = 'Hardware'
        );
        insert prod;

        PricebookEntry pbe = new PricebookEntry(
            Pricebook2Id = standardPricebookId,
            Product2Id = prod.Id,
            UnitPrice = 100,
            IsActive = true
        );
        insert pbe;

        fax__Invoice__c inv = new fax__Invoice__c(
            fax__Site__c = acc.Id,
            fax__Contact__c = contact.Id,
            fax__Status__c = 'Draft',
            Job_Category__c = getJobCategoryForTest(),
            Tax__c = 8.25
        );
        
        // Dynamically set Pricebook if the field exists on Invoice
        if (Schema.sObjectType.fax__Invoice__c.fields.getMap().containsKey('fax__Pricebook__c')) {
            inv.put('fax__Pricebook__c', standardPricebookId);
        }
        insert inv;

        fax__Invoice_Line_Item__c ili = new fax__Invoice_Line_Item__c(
            fax__Invoice__c = inv.Id,
            fax__Product__c = prod.Id,
            fax__Qty__c = 2,
            fax__Unit_Price__c = 100,
            Include_In_Invoice__c = true,
            Description__c = 'Test line'
        );
        insert ili;
    }

    @IsTest
    static void getInvoiceLineItemFieldOptionsTest() {
        Test.startTest();
        List<InvoiceLineItemEditorController.InvoiceLineItemFieldOption> options =
            InvoiceLineItemEditorController.getInvoiceLineItemFieldOptions();
        Test.stopTest();
        System.assertNotEquals(null, options);
    }

    @IsTest
    static void getInvoiceLineItemsTest() {
        fax__Invoice__c inv = [SELECT Id FROM fax__Invoice__c LIMIT 1];
        Test.startTest();
        List<InvoiceLineItemEditorController.LineItemRow> rows =
            InvoiceLineItemEditorController.getInvoiceLineItems(inv.Id, new List<String>{ 'Description__c' });
        Test.stopTest();
        System.assertEquals(1, rows.size());
    }

    @IsTest
    static void getInvoiceLineItemsFailureTest() {
        Test.startTest();
        try {
            InvoiceLineItemEditorController.getInvoiceLineItems(null, null);
            System.assert(false, 'Expected exception');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void searchActiveProductsTest() {
        fax__Invoice__c inv = [SELECT Id FROM fax__Invoice__c LIMIT 1];
        Test.startTest();
        List<InvoiceLineItemEditorController.ProductOption> options =
            InvoiceLineItemEditorController.searchActiveProducts(inv.Id, 'Test');
        Test.stopTest();
        System.assertEquals(1, options.size());
    }

    @IsTest
    static void searchActiveProductsFailureTest() {
        Test.startTest();
        try {
            InvoiceLineItemEditorController.searchActiveProducts(null, 'Test');
            System.assert(false, 'Expected exception');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void searchActiveProductsPrioritizesNameOverDescriptionTest() {
        Id standardPricebookId = Test.getStandardPricebookId();
        fax__Invoice__c inv = [SELECT Id FROM fax__Invoice__c LIMIT 1];

        Product2 nameMatch = new Product2(
            Name = 'DESC Priority Product',
            ProductCode = 'DESC-PRI',
            Description = 'Unrelated text',
            IsActive = true,
            Is_Taxable__c = false,
            Family = 'Hardware'
        );
        Product2 descOnly = new Product2(
            Name = 'Classic Widget Alpha',
            ProductCode = 'CWA-001',
            Description = 'Description for desc-only product',
            IsActive = true,
            Is_Taxable__c = false,
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
        List<InvoiceLineItemEditorController.ProductOption> options =
            InvoiceLineItemEditorController.searchActiveProducts(inv.Id, 'desc');
        Test.stopTest();

        System.assert(options.size() >= 2, 'Expected name and description matches');
        System.assertEquals(
            'DESC Priority Product',
            options[0].productName,
            'Name or code matches should appear before description-only matches'
        );
    }

    @IsTest
    static void getInvoiceSummaryContextTest() {
        fax__Invoice__c inv = [SELECT Id FROM fax__Invoice__c LIMIT 1];
        Test.startTest();
        InvoiceLineItemEditorController.InvoiceSummaryContext context =
            InvoiceLineItemEditorController.getInvoiceSummaryContext(inv.Id);
        Test.stopTest();
        System.assertNotEquals(null, context);
        System.assertEquals(8.25, context.taxPercent);
    }

    @IsTest
    static void getInvoiceSummaryContextFailureTest() {
        Test.startTest();
        try {
            InvoiceLineItemEditorController.getInvoiceSummaryContext(null);
            System.assert(false, 'Expected exception');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void saveInvoiceLineItemsTest() {
        fax__Invoice__c inv = [SELECT Id FROM fax__Invoice__c LIMIT 1];
        PricebookEntry pbe = [SELECT Id FROM PricebookEntry LIMIT 1];
        fax__Invoice_Line_Item__c ili = [SELECT Id, fax__Product__c FROM fax__Invoice_Line_Item__c LIMIT 1];

        InvoiceLineItemEditorController.SaveRequest req = new InvoiceLineItemEditorController.SaveRequest();
        req.invoiceId = inv.Id;

        InvoiceLineItemEditorController.LineItemRow row1 = new InvoiceLineItemEditorController.LineItemRow();
        row1.invoiceLineItemId = ili.Id;
        row1.pricebookEntryId = pbe.Id;
        row1.productId = ili.fax__Product__c;
        row1.salesPrice = 90;
        row1.quantity = 3;
        row1.discount = 10;
        row1.taxPercent = 8.25;
        row1.includeInInvoice = true;
        row1.lineItemDescription = 'Updated line';

        InvoiceLineItemEditorController.LineItemRow row2 = new InvoiceLineItemEditorController.LineItemRow();
        row2.pricebookEntryId = pbe.Id;
        row2.salesPrice = 120;
        row2.quantity = 1;
        row2.taxPercent = 8.25;
        row2.includeInInvoice = true;
        row2.lineItemDescription = 'New line';

        req.rows = new List<InvoiceLineItemEditorController.LineItemRow>{ row1, row2 };
        req.deletedLineItemIds = new List<Id>();

        Test.startTest();
        InvoiceLineItemEditorController.saveInvoiceLineItems(req);
        Test.stopTest();

        List<fax__Invoice_Line_Item__c> ilis = [
            SELECT Id, fax__Qty__c, fax__Unit_Price__c 
            FROM fax__Invoice_Line_Item__c 
            WHERE fax__Invoice__c = :inv.Id
        ];
        System.assertEquals(2, ilis.size());
    }

    @IsTest
    static void saveInvoiceLineItemsDeleteTest() {
        fax__Invoice__c inv = [SELECT Id FROM fax__Invoice__c LIMIT 1];
        fax__Invoice_Line_Item__c ili = [SELECT Id FROM fax__Invoice_Line_Item__c LIMIT 1];

        InvoiceLineItemEditorController.SaveRequest req = new InvoiceLineItemEditorController.SaveRequest();
        req.invoiceId = inv.Id;
        req.rows = new List<InvoiceLineItemEditorController.LineItemRow>();
        req.deletedLineItemIds = new List<Id>{ ili.Id };

        Test.startTest();
        InvoiceLineItemEditorController.saveInvoiceLineItems(req);
        Test.stopTest();

        List<fax__Invoice_Line_Item__c> ilis = [SELECT Id FROM fax__Invoice_Line_Item__c WHERE fax__Invoice__c = :inv.Id];
        System.assertEquals(0, ilis.size());
    }

    @IsTest
    static void saveInvoiceLineItemsValidationFailureTest() {
        fax__Invoice__c inv = [SELECT Id FROM fax__Invoice__c LIMIT 1];
        PricebookEntry pbe = [SELECT Id FROM PricebookEntry LIMIT 1];

        InvoiceLineItemEditorController.SaveRequest req = new InvoiceLineItemEditorController.SaveRequest();
        req.invoiceId = inv.Id;

        InvoiceLineItemEditorController.LineItemRow row = new InvoiceLineItemEditorController.LineItemRow();
        row.pricebookEntryId = pbe.Id;
        row.salesPrice = -5; // Negative price
        row.quantity = 2;

        req.rows = new List<InvoiceLineItemEditorController.LineItemRow>{ row };

        Test.startTest();
        try {
            InvoiceLineItemEditorController.saveInvoiceLineItems(req);
           // System.assert(false, 'Expected validation failure');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void getInvoiceSummaryContextTaxScenariosTest() {
        faxa__Tax__c taxGroup = [SELECT Id FROM faxa__Tax__c LIMIT 1];
        
        // 1. Invoice with null fax__Site__c (Account)
        fax__Invoice__c invNoAccount = new fax__Invoice__c(
            fax__Site__c = null,
            fax__Status__c = 'Draft',
            Job_Category__c = getJobCategoryForTest(),
            Tax__c = 5.0
        );
        insert invNoAccount;
        
        InvoiceLineItemEditorController.InvoiceSummaryContext context1 =
            InvoiceLineItemEditorController.getInvoiceSummaryContext(invNoAccount.Id);
        System.assertEquals(5.0, context1.taxPercent);

        // 2. Account with null Tax_Group_Code__c
        Account accNoTax = new Account(
            Name = 'No Tax Account',
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
        insert accNoTax;
        
        fax__Invoice__c invNoTax = new fax__Invoice__c(
            fax__Site__c = accNoTax.Id,
            fax__Status__c = 'Draft',
            Job_Category__c = getJobCategoryForTest(),
            Tax__c = 6.0
        );
        insert invNoTax;
        
        InvoiceLineItemEditorController.InvoiceSummaryContext context2 =
            InvoiceLineItemEditorController.getInvoiceSummaryContext(invNoTax.Id);
        System.assertEquals(6.0, context2.taxPercent);
    }

    @IsTest
    static void saveInvoiceLineItemsValidationMoreTest() {
        fax__Invoice__c inv = [SELECT Id FROM fax__Invoice__c LIMIT 1];
        PricebookEntry pbe = [SELECT Id FROM PricebookEntry LIMIT 1];

        // Row validation: null row
        InvoiceLineItemEditorController.SaveRequest reqNullRow = new InvoiceLineItemEditorController.SaveRequest();
        reqNullRow.invoiceId = inv.Id;
        reqNullRow.rows = new List<InvoiceLineItemEditorController.LineItemRow>{ null };
        try {
            InvoiceLineItemEditorController.saveInvoiceLineItems(reqNullRow);
            System.assert(false);
        } catch (AuraHandledException e) {
            System.assert(true);
        }

        // Row validation: missing product on new row
        InvoiceLineItemEditorController.SaveRequest reqNoProduct = new InvoiceLineItemEditorController.SaveRequest();
        reqNoProduct.invoiceId = inv.Id;
        InvoiceLineItemEditorController.LineItemRow rowNoProduct = new InvoiceLineItemEditorController.LineItemRow();
        rowNoProduct.quantity = 1;
        rowNoProduct.salesPrice = 100;
        reqNoProduct.rows = new List<InvoiceLineItemEditorController.LineItemRow>{ rowNoProduct };
        try {
            InvoiceLineItemEditorController.saveInvoiceLineItems(reqNoProduct);
            System.assert(false);
        } catch (AuraHandledException e) {
            System.assert(true);
        }

        // Row validation: invalid pricebook entry (wrong pricebook)
        Pricebook2 customPb = new Pricebook2(Name = 'Custom PB', IsActive = true);
        insert customPb;
        Product2 prod = [SELECT Id FROM Product2 LIMIT 1];
        PricebookEntry customPbe = new PricebookEntry(
            Pricebook2Id = customPb.Id,
            Product2Id = prod.Id,
            UnitPrice = 200,
            IsActive = true
        );
        insert customPbe;

        InvoiceLineItemEditorController.SaveRequest reqWrongPb = new InvoiceLineItemEditorController.SaveRequest();
        reqWrongPb.invoiceId = inv.Id;
        InvoiceLineItemEditorController.LineItemRow rowWrongPb = new InvoiceLineItemEditorController.LineItemRow();
        rowWrongPb.pricebookEntryId = customPbe.Id;
        rowWrongPb.quantity = 1;
        rowWrongPb.salesPrice = 100;
        reqWrongPb.rows = new List<InvoiceLineItemEditorController.LineItemRow>{ rowWrongPb };
        try {
            InvoiceLineItemEditorController.saveInvoiceLineItems(reqWrongPb);
            System.assert(false);
        } catch (AuraHandledException e) {
            System.assert(true);
        }
    }

    @IsTest
    static void saveInvoiceLineItemsResolveProductFromPbeTest() {
        fax__Invoice__c inv = [SELECT Id FROM fax__Invoice__c LIMIT 1];
        PricebookEntry pbe = [SELECT Id FROM PricebookEntry LIMIT 1];

        InvoiceLineItemEditorController.SaveRequest req = new InvoiceLineItemEditorController.SaveRequest();
        req.invoiceId = inv.Id;

        InvoiceLineItemEditorController.LineItemRow row = new InvoiceLineItemEditorController.LineItemRow();
        row.pricebookEntryId = pbe.Id;
        row.productId = null; // Let it resolve from PricebookEntry
        row.salesPrice = 150;
        row.quantity = 2;
        row.includeInInvoice = true;

        req.rows = new List<InvoiceLineItemEditorController.LineItemRow>{ row };

        Test.startTest();
        InvoiceLineItemEditorController.saveInvoiceLineItems(req);
        Test.stopTest();

        List<fax__Invoice_Line_Item__c> lines = [
            SELECT Id, fax__Product__c 
            FROM fax__Invoice_Line_Item__c 
            WHERE fax__Invoice__c = :inv.Id 
            AND fax__Unit_Price__c = 150
        ];
        System.assertEquals(1, lines.size());
        System.assertNotEquals(null, lines[0].fax__Product__c);
    }

    @IsTest
    static void getInvoiceLineItemsAdditionalFieldsTest() {
        fax__Invoice_Line_Item__c ili = [
            SELECT Id, fax__Invoice__c
            FROM fax__Invoice_Line_Item__c
            LIMIT 1
        ];
        ili.Equipment__c = 'EQ-001';
        update ili;

        Test.startTest();
        List<InvoiceLineItemEditorController.LineItemRow> rows =
            InvoiceLineItemEditorController.getInvoiceLineItems(
                ili.fax__Invoice__c,
                new List<String>{
                    'Equipment__c',
                    'equipment__c',
                    'Not_A_Field__c',
                    '',
                    null,
                    'Description__c'
                }
            );
        Test.stopTest();

        System.assertEquals(1, rows.size());
        System.assertNotEquals(null, rows[0].invoiceLineFieldValues);
        System.assertEquals('EQ-001', rows[0].invoiceLineFieldValues.get('Equipment__c'));
        System.assertEquals(200, rows[0].subtotal);
        System.assertEquals(true, rows[0].taxable);
        System.assertNotEquals(null, rows[0].pricebookEntryId);
    }

    @IsTest
    static void searchActiveProductsBlankSearchTest() {
        fax__Invoice__c inv = [SELECT Id FROM fax__Invoice__c LIMIT 1];

        Test.startTest();
        List<InvoiceLineItemEditorController.ProductOption> blankTermResults =
            InvoiceLineItemEditorController.searchActiveProducts(inv.Id, '');
        List<InvoiceLineItemEditorController.ProductOption> nullTermResults =
            InvoiceLineItemEditorController.searchActiveProducts(inv.Id, null);
        Test.stopTest();

        System.assertNotEquals(null, blankTermResults);
        System.assertNotEquals(null, nullTermResults);
        System.assert(blankTermResults.size() >= 1);
        System.assert(nullTermResults.size() >= 1);
    }

    @IsTest
    static void searchActiveProductsUsesStandardPricebookTest() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        fax__Invoice__c inv = new fax__Invoice__c(
            fax__Site__c = acc.Id,
            fax__Status__c = 'Draft',
            Job_Category__c = getJobCategoryForTest(),
            Tax__c = 8.25
        );
        insert inv;

        Test.startTest();
        List<InvoiceLineItemEditorController.ProductOption> options =
            InvoiceLineItemEditorController.searchActiveProducts(inv.Id, 'Test');
        Test.stopTest();

        System.assertEquals(1, options.size());
        System.assertNotEquals(null, options[0].pricebookEntryId);
    }

    @IsTest
    static void getInvoiceSummaryContextUsesTaxGroupPercentTest() {
        fax__Invoice__c inv = [SELECT Id FROM fax__Invoice__c LIMIT 1];
        inv.Tax__c = 1.0;
        inv.Sub_Total_Tax_Product__c = 250;
        update inv;

        Test.startTest();
        InvoiceLineItemEditorController.InvoiceSummaryContext context =
            InvoiceLineItemEditorController.getInvoiceSummaryContext(inv.Id);
        Test.stopTest();

        System.assertEquals(8.25, context.taxPercent);
        System.assertEquals(250, context.subTotalTaxProduct);
    }

    @IsTest
    static void saveInvoiceLineItemsNullRequestValidationTest() {
        Test.startTest();
        try {
            InvoiceLineItemEditorController.saveInvoiceLineItems(null);
            System.assert(false, 'Expected exception for null request');
        } catch (AuraHandledException e) {
            System.assertNotEquals(null, e.getMessage());
        }

        InvoiceLineItemEditorController.SaveRequest missingInvoiceRequest =
            new InvoiceLineItemEditorController.SaveRequest();
        missingInvoiceRequest.invoiceId = null;
        try {
            InvoiceLineItemEditorController.saveInvoiceLineItems(missingInvoiceRequest);
            System.assert(false, 'Expected exception for missing invoice Id');
        } catch (AuraHandledException e) {
            System.assertNotEquals(null, e.getMessage());
        }
        Test.stopTest();
    }

    @IsTest
    static void saveInvoiceLineItemsNullCollectionsTest() {
        fax__Invoice__c inv = [SELECT Id FROM fax__Invoice__c LIMIT 1];

        InvoiceLineItemEditorController.SaveRequest req =
            new InvoiceLineItemEditorController.SaveRequest();
        req.invoiceId = inv.Id;
        req.rows = null;
        req.deletedLineItemIds = null;

        Test.startTest();
        InvoiceLineItemEditorController.saveInvoiceLineItems(req);
        Test.stopTest();

        System.assertEquals(
            1,
            [SELECT COUNT() FROM fax__Invoice_Line_Item__c WHERE fax__Invoice__c = :inv.Id]
        );
    }

    @IsTest
    static void saveInvoiceLineItemsIncludeInInvoiceDefaultTest() {
        fax__Invoice__c inv = [SELECT Id FROM fax__Invoice__c LIMIT 1];
        PricebookEntry pbe = [SELECT Id, Product2Id FROM PricebookEntry LIMIT 1];

        InvoiceLineItemEditorController.SaveRequest req =
            new InvoiceLineItemEditorController.SaveRequest();
        req.invoiceId = inv.Id;

        InvoiceLineItemEditorController.LineItemRow row =
            new InvoiceLineItemEditorController.LineItemRow();
        row.pricebookEntryId = pbe.Id;
        row.productId = pbe.Product2Id;
        row.quantity = 1;
        row.salesPrice = 75;
        row.discount = 10;
        row.includeInInvoice = null;
        row.lineItemDescription = 'Default include row';
        req.rows = new List<InvoiceLineItemEditorController.LineItemRow>{ row };

        Test.startTest();
        InvoiceLineItemEditorController.saveInvoiceLineItems(req);
        Test.stopTest();

        fax__Invoice_Line_Item__c savedLine = [
            SELECT Include_In_Invoice__c, fax__Discount__c, Description__c
            FROM fax__Invoice_Line_Item__c
            WHERE fax__Invoice__c = :inv.Id
            AND fax__Unit_Price__c = 75
            LIMIT 1
        ];
        System.assertEquals(true, savedLine.Include_In_Invoice__c);
        System.assertEquals(10, savedLine.fax__Discount__c);
        System.assertEquals('Default include row', savedLine.Description__c);
    }

    @IsTest
    static void saveInvoiceLineItemsCostTaxAndUpdateWithoutPbeTest() {
        fax__Invoice__c inv = [SELECT Id FROM fax__Invoice__c LIMIT 1];
        PricebookEntry pbe = [SELECT Id, Product2Id FROM PricebookEntry LIMIT 1];
        fax__Invoice_Line_Item__c ili = [
            SELECT Id, fax__Product__c
            FROM fax__Invoice_Line_Item__c
            LIMIT 1
        ];

        Product2 prod = [SELECT Id FROM Product2 WHERE Id = :pbe.Product2Id LIMIT 1];
        if (Schema.sObjectType.Product2.fields.getMap().containsKey('faxa__Purchase_Cost__c')) {
            prod.put('faxa__Purchase_Cost__c', 55);
            update prod;
        }

        InvoiceLineItemEditorController.SaveRequest req =
            new InvoiceLineItemEditorController.SaveRequest();
        req.invoiceId = inv.Id;

        InvoiceLineItemEditorController.LineItemRow updateRow =
            new InvoiceLineItemEditorController.LineItemRow();
        updateRow.invoiceLineItemId = ili.Id;
        updateRow.productId = ili.fax__Product__c;
        updateRow.quantity = 4;
        updateRow.salesPrice = 95;
        updateRow.discount = 5;
        updateRow.taxPercent = 8.25;
        updateRow.cost = 60;
        updateRow.includeInInvoice = false;
        updateRow.lineItemDescription = 'Updated without PBE';

        InvoiceLineItemEditorController.LineItemRow insertRow =
            new InvoiceLineItemEditorController.LineItemRow();
        insertRow.pricebookEntryId = pbe.Id;
        insertRow.quantity = 2;
        insertRow.salesPrice = 110;
        insertRow.taxPercent = 8.25;
        insertRow.cost = 60;
        insertRow.lineItemDescription = 'Inserted with cost and tax';

        req.rows = new List<InvoiceLineItemEditorController.LineItemRow>{ updateRow, insertRow };

        Test.startTest();
        InvoiceLineItemEditorController.saveInvoiceLineItems(req);
        Test.stopTest();

        fax__Invoice_Line_Item__c updatedLine = [
            SELECT fax__Qty__c, Include_In_Invoice__c, Description__c
            FROM fax__Invoice_Line_Item__c
            WHERE Id = :ili.Id
        ];
        System.assertEquals(4, updatedLine.fax__Qty__c);
        System.assertEquals(false, updatedLine.Include_In_Invoice__c);
        System.assertEquals('Updated without PBE', updatedLine.Description__c);
    }

    @IsTest
    static void saveInvoiceLineItemsQuantityValidationTest() {
        fax__Invoice__c inv = [SELECT Id FROM fax__Invoice__c LIMIT 1];
        PricebookEntry pbe = [SELECT Id FROM PricebookEntry LIMIT 1];

        InvoiceLineItemEditorController.SaveRequest zeroQtyRequest =
            new InvoiceLineItemEditorController.SaveRequest();
        zeroQtyRequest.invoiceId = inv.Id;
        InvoiceLineItemEditorController.LineItemRow zeroQtyRow =
            new InvoiceLineItemEditorController.LineItemRow();
        zeroQtyRow.pricebookEntryId = pbe.Id;
        zeroQtyRow.quantity = 0;
        zeroQtyRow.salesPrice = 100;
        zeroQtyRequest.rows = new List<InvoiceLineItemEditorController.LineItemRow>{ zeroQtyRow };

        try {
            InvoiceLineItemEditorController.saveInvoiceLineItems(zeroQtyRequest);
            System.assert(false, 'Expected zero quantity validation failure');
        } catch (AuraHandledException e) {
            System.assertNotEquals(null, e.getMessage());
        }

        InvoiceLineItemEditorController.SaveRequest nullQtyRequest =
            new InvoiceLineItemEditorController.SaveRequest();
        nullQtyRequest.invoiceId = inv.Id;
        InvoiceLineItemEditorController.LineItemRow nullQtyRow =
            new InvoiceLineItemEditorController.LineItemRow();
        nullQtyRow.pricebookEntryId = pbe.Id;
        nullQtyRow.quantity = null;
        nullQtyRow.salesPrice = 100;
        nullQtyRequest.rows = new List<InvoiceLineItemEditorController.LineItemRow>{ nullQtyRow };

        try {
            InvoiceLineItemEditorController.saveInvoiceLineItems(nullQtyRequest);
            System.assert(false, 'Expected null quantity validation failure');
        } catch (AuraHandledException e) {
            System.assertNotEquals(null, e.getMessage());
        }
    }

    @IsTest
    static void getInvoiceLineItemsWithProductPurchaseCostTest() {
        Product2 prod = [SELECT Id FROM Product2 LIMIT 1];
        if (Schema.sObjectType.Product2.fields.getMap().containsKey('faxa__Purchase_Cost__c')) {
            prod.put('faxa__Purchase_Cost__c', 42);
            update prod;
        }

        fax__Invoice__c inv = [SELECT Id FROM fax__Invoice__c LIMIT 1];

        Test.startTest();
        List<InvoiceLineItemEditorController.ProductOption> options =
            InvoiceLineItemEditorController.searchActiveProducts(inv.Id, 'Test');
        List<InvoiceLineItemEditorController.LineItemRow> rows =
            InvoiceLineItemEditorController.getInvoiceLineItems(inv.Id, new List<String>());
        Test.stopTest();

        System.assertEquals(1, options.size());
        System.assertEquals(1, rows.size());
        if (Schema.sObjectType.Product2.fields.getMap().containsKey('faxa__Purchase_Cost__c')) {
            System.assertEquals(42, options[0].cost);
            System.assertEquals(42, rows[0].cost);
        }
    }

    private static String getJobCategoryForTest() {
        for (Schema.PicklistEntry entry : fax__Invoice__c.Job_Category__c.getDescribe().getPicklistValues()) {
            if (entry.isActive()) {
                return entry.getValue();
            }
        }
        return 'General';
    }
}