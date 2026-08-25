@IsTest
private class ProductTriggerHandlerTest {

    private static Id setupStandardPricebook() {
        Id standardPricebookId = Test.getStandardPricebookId();
        update new Pricebook2(Id = standardPricebookId, IsActive = true);
        return standardPricebookId;
    }

    private static faxa__External_App__c setupQuickBookApp() {
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
        return app;
    }

    private static Product2 buildTestProduct(String name) {
        return buildTestProduct(name, null);
    }

    private static Product2 buildTestProduct(String name, String productCode) {
        return new Product2(
            Name = name,
            ProductCode = productCode,
            IsActive = true,
            Family = 'Hardware'
        );
    }

    private static void setupProductMappings(Id appId) {
        List<faxa__Mapping__c> mappings = new List<faxa__Mapping__c>{
            new faxa__Mapping__c(
                faxa__FieldAx_Object__c = 'Product2',
                faxa__FieldAx_Field__c = 'Name',
                faxa__External_App_Field__c = 'Name',
                faxa__External_App__c = appId,
                faxa__Sequence__c = 1
            ),
            new faxa__Mapping__c(
                faxa__FieldAx_Object__c = 'Product2',
                faxa__FieldAx_Field__c = 'Description',
                faxa__External_App_Field__c = 'Description',
                faxa__External_App__c = appId,
                faxa__Sequence__c = 2
            )
        };
        insert mappings;
    }

    @IsTest
    static void testInsertCreatesPricebookEntry() {

        Id standardPricebookId = setupStandardPricebook();

        Product2 productRecord = buildTestProduct('Insert Test Product');
        productRecord.put('faxa__Sales_Price__c', 123.45);
        productRecord.put('faxa__Purchase_Cost__c', 98.76);

        Test.startTest();
        insert productRecord;
        Test.stopTest();

        PricebookEntry pbe = [
            SELECT Pricebook2Id, Product2Id, UnitPrice, IsActive, Cost__c
            FROM PricebookEntry
            WHERE Pricebook2Id = :standardPricebookId
            AND Product2Id = :productRecord.Id
            LIMIT 1
        ];

        System.assertEquals(standardPricebookId, pbe.Pricebook2Id);
        System.assertEquals(productRecord.Id, pbe.Product2Id);
        System.assertEquals(123.45, pbe.UnitPrice);
        System.assertEquals(98.76, (Decimal)pbe.get('Cost__c'));
        System.assertEquals(true, pbe.IsActive);
    }

    @IsTest
    static void testUpdateWhenActive() {

        Id standardPricebookId = setupStandardPricebook();

        Product2 productRecord = buildTestProduct('Update Active Test');
        productRecord.put('faxa__Sales_Price__c', 50);
        productRecord.put('faxa__Purchase_Cost__c', 25);

        insert productRecord;

        // Update values (still active)
        productRecord.put('faxa__Sales_Price__c', 77.77);
        productRecord.put('faxa__Purchase_Cost__c', 44.44);

        Test.startTest();
        update productRecord;
        Test.stopTest();

        PricebookEntry pbe = [
            SELECT UnitPrice, IsActive, Cost__c
            FROM PricebookEntry
            WHERE Product2Id = :productRecord.Id
            AND Pricebook2Id = :standardPricebookId
            LIMIT 1
        ];

        System.assertEquals(77.77, pbe.UnitPrice);
        System.assertEquals(44.44, (Decimal)pbe.get('Cost__c'));
        System.assertEquals(true, pbe.IsActive);
    }

    @IsTest
    static void testUpdateSkippedWhenInactive() {

        Id standardPricebookId = setupStandardPricebook();

        Product2 productRecord = buildTestProduct('Update Inactive Test');
        productRecord.put('faxa__Sales_Price__c', 60);

        insert productRecord;

        // Get original entry
        PricebookEntry beforeUpdate = [
            SELECT UnitPrice
            FROM PricebookEntry
            WHERE Product2Id = :productRecord.Id
            LIMIT 1
        ];

        // Make inactive + change price
        productRecord.IsActive = false;
        productRecord.put('faxa__Sales_Price__c', 999);

        Test.startTest();
        update productRecord;
        Test.stopTest();

        PricebookEntry afterUpdate = [
            SELECT UnitPrice
            FROM PricebookEntry
            WHERE Product2Id = :productRecord.Id
            LIMIT 1
        ];

        // Should NOT change because handler skips inactive products
        System.assertEquals(beforeUpdate.UnitPrice, afterUpdate.UnitPrice);
    }

    @IsTest
    static void testNoPriceNoEntryCreated() {

        Id standardPricebookId = setupStandardPricebook();

        Product2 productRecord = buildTestProduct('No Price Test');

        insert productRecord;

        List<PricebookEntry> entries = [
            SELECT Id
            FROM PricebookEntry
            WHERE Product2Id = :productRecord.Id
        ];

        System.assertEquals(0, entries.size(),
            'No PricebookEntry should be created when price is null');
    }

    @IsTest
    static void testDeleteHandler() {

        Id standardPricebookId = setupStandardPricebook();

        Product2 productRecord = buildTestProduct('Delete Test');
        productRecord.put('faxa__Sales_Price__c', 100);

        insert productRecord;

        // Ensure entry exists
        List<PricebookEntry> beforeDelete = [
            SELECT Id, IsActive
            FROM PricebookEntry
            WHERE Product2Id = :productRecord.Id
        ];
        System.assert(!beforeDelete.isEmpty(), 'Entry should exist before delete');

        Test.startTest();
        delete productRecord;
        Test.stopTest();

        List<PricebookEntry> afterDelete = [
            SELECT Id, IsActive
            FROM PricebookEntry
            WHERE Product2Id = :productRecord.Id
        ];

        for (PricebookEntry pbe : afterDelete) {
            System.assertEquals(false, pbe.IsActive,
                'Entries should be deactivated on delete');
        }
    }

    @IsTest
    static void testBulkInsertAndUpdate() {

        Id standardPricebookId = setupStandardPricebook();

        List<Product2> products = new List<Product2>();

        for (Integer i = 0; i < 200; i++) {
            Product2 p = buildTestProduct('Bulk Product ' + i, 'BULK-' + i);
            p.put('faxa__Sales_Price__c', 10 + i);
            products.add(p);
        }

        Test.startTest();
        insert products;

        // Update all
        for (Product2 p : products) {
            p.put('faxa__Sales_Price__c', 200 + products.indexOf(p));
        }
        update products;
        Test.stopTest();

        List<PricebookEntry> entries = [
            SELECT Id
            FROM PricebookEntry
            WHERE Product2Id IN :products
        ];

        System.assertEquals(200, entries.size(),
            'All products should have PricebookEntries');
    }

    @IsTest
    static void testSyncFlagSetOnInsert() {
        Id standardPricebookId = setupStandardPricebook();

        Product2 prod = buildTestProduct('Insert Sync Product');
        prod.put('faxa__Sales_Price__c', 75);

        Test.startTest();
        insert prod;
        Test.stopTest();

        Product2 result = [
            SELECT faxa__Sync_to_QuickBooks__c FROM Product2 WHERE Id = :prod.Id
        ];
        System.assertEquals(true, result.faxa__Sync_to_QuickBooks__c,
            'Sync flag should be true on insert');
    }

    @IsTest
    static void testSyncFlagSetOnMappedFieldChange() {
        Id standardPricebookId = setupStandardPricebook();
        faxa__External_App__c app = setupQuickBookApp();
        setupProductMappings(app.Id);

        Product2 prod = buildTestProduct('Sync Test Product');
        prod.Description = 'Original';
        prod.put('faxa__Sales_Price__c', 50);
        insert prod;

        prod.Description = 'Updated';

        Test.startTest();
        update prod;
        Test.stopTest();

        Product2 result = [
            SELECT faxa__Sync_to_QuickBooks__c FROM Product2 WHERE Id = :prod.Id
        ];
        System.assertEquals(true, result.faxa__Sync_to_QuickBooks__c,
            'Sync flag should be true when a mapped field changes');
    }

    @IsTest
    static void testSyncFlagNotSetWhenNoMappedFieldChanges() {
        Id standardPricebookId = setupStandardPricebook();
        faxa__External_App__c app = setupQuickBookApp();
        setupProductMappings(app.Id);

        Product2 prod = buildTestProduct('No Sync Product', 'OLD-CODE');
        prod.put('faxa__Sales_Price__c', 50);
        insert prod;

        update new Product2(Id = prod.Id, faxa__Sync_to_QuickBooks__c = false);

        prod.ProductCode = 'NEW-CODE';

        Test.startTest();
        update prod;
        Test.stopTest();

        Product2 result = [
            SELECT faxa__Sync_to_QuickBooks__c FROM Product2 WHERE Id = :prod.Id
        ];
        System.assertEquals(false, result.faxa__Sync_to_QuickBooks__c,
            'Sync flag should remain false when only unmapped fields change');
    }

    @IsTest
    static void testSyncWithNoMappings() {
        Id standardPricebookId = setupStandardPricebook();

        Product2 prod = buildTestProduct('No Mapping Product');
        prod.put('faxa__Sales_Price__c', 50);
        insert prod;

        update new Product2(Id = prod.Id, faxa__Sync_to_QuickBooks__c = false);

        prod.Name = 'Updated No Mapping Product';

        Test.startTest();
        update prod;
        Test.stopTest();

        Product2 result = [
            SELECT faxa__Sync_to_QuickBooks__c FROM Product2 WHERE Id = :prod.Id
        ];
        System.assertEquals(false, result.faxa__Sync_to_QuickBooks__c,
            'Sync flag should remain false when no mappings exist');
    }

    @IsTest
    static void testBulkSyncUpdate() {
        Id standardPricebookId = setupStandardPricebook();
        faxa__External_App__c app = setupQuickBookApp();
        setupProductMappings(app.Id);

        List<Product2> products = new List<Product2>();
        for (Integer i = 0; i < 200; i++) {
            Product2 p = buildTestProduct('Bulk Sync Product ' + i, 'BSYNC-' + i);
            p.put('faxa__Sales_Price__c', 10 + i);
            products.add(p);
        }
        insert products;

        for (Product2 p : products) {
            p.Name = p.Name + ' Updated';
        }

        Test.startTest();
        update products;
        Test.stopTest();

        List<Product2> results = [
            SELECT faxa__Sync_to_QuickBooks__c FROM Product2
            WHERE Id IN :products AND faxa__Sync_to_QuickBooks__c = true
        ];
        System.assertEquals(200, results.size(),
            'All 200 products should have sync flag set to true');
    }

    @IsTest
    static void testQuickBooksRecursionGuardSkipsRepeatSyncDml() {
        setupStandardPricebook();
        faxa__External_App__c app = setupQuickBookApp();
        setupProductMappings(app.Id);

        Product2 prod = buildTestProduct('Recursion Guard Product');
        prod.put('faxa__Sales_Price__c', 25);
        insert prod;

        System.assert(
            ProductTriggerHandler.quickBooksSyncedThisTransaction.contains(prod.Id),
            'Insert should register the product in the recursion guard'
        );

        Product2 oldSnapshot = prod.clone(true, true, true, true);
        prod.Description = 'Simulated re-entrant trigger fire';

        Integer dmlBefore = Limits.getDmlStatements();
        ProductTriggerHandler.handleAfterUpdate(
            new List<Product2>{ prod },
            new Map<Id, Product2>{ prod.Id => oldSnapshot }
        );
        Integer dmlAfter = Limits.getDmlStatements();

        System.assertEquals(
            dmlBefore,
            dmlAfter,
            'Recursion guard should skip a second QB sync update for the same product'
        );
    }

    @IsTest
    static void testBrowseProductsForListView_returnsRows() {
        setupStandardPricebook();
        insert buildTestProduct('Browse List Product', 'BROWSE-1');

        Test.startTest();
        ProductTriggerHandler.ListViewSearchResult result =
            ProductTriggerHandler.browseProductsForListView(
                50,
                1,
                'Name',
                'ASC',
                null,
                null,
                'all',
                null,
                null
            );
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assert(result.totalCount >= 1, 'Expected at least one product');
        System.assert(!result.records.isEmpty(), 'Expected browse rows');
    }

    @IsTest
    static void testProductListViewDisplayConfig_saveAndLoad() {
        Test.startTest();
        ProductTriggerHandler.ListViewDisplayConfig saved =
            ProductTriggerHandler.saveProductListViewDisplayConfig(
                'AllProducts',
                'All Products',
                false,
                new List<String>{ 'Name', 'ProductCode', 'Description' },
                null,
                'all',
                'Name',
                'ASC'
            );
        List<ProductTriggerHandler.ListViewDisplayConfig> configs =
            ProductTriggerHandler.getProductListViewDisplayConfigs();
        Test.stopTest();

        System.assertEquals('AllProducts', saved.viewKey);
        System.assert(saved.selectedColumnFields.contains('Description'));
        Boolean found = false;
        for (ProductTriggerHandler.ListViewDisplayConfig cfg : configs) {
            if ('AllProducts'.equals(cfg.viewKey)) {
                found = true;
                System.assert(cfg.selectedColumnFields.contains('Description'));
            }
        }
        System.assert(found, 'Expected saved AllProducts config');
    }

    @IsTest
    static void testProductListViewDisplayConfig_preservesColumnOrder() {
        List<String> orderedColumns = new List<String>{
            'Name',
            'Description',
            'ProductCode',
            'Family',
            'IsActive'
        };

        Test.startTest();
        ProductTriggerHandler.ListViewDisplayConfig saved =
            ProductTriggerHandler.saveProductListViewDisplayConfig(
                'AllProducts',
                'All Products',
                false,
                orderedColumns,
                null,
                'all',
                'Name',
                'ASC'
            );
        Test.stopTest();

        System.assertEquals(5, saved.selectedColumnFields.size());
        System.assertEquals('Name', saved.selectedColumnFields[0]);
        System.assertEquals('Description', saved.selectedColumnFields[1]);
        System.assertEquals('ProductCode', saved.selectedColumnFields[2]);
        System.assertEquals('Family', saved.selectedColumnFields[3]);
        System.assertEquals('IsActive', saved.selectedColumnFields[4]);
    }

    @IsTest
    static void testProductListViewDisplayConfig_deleteCustomView() {
        ProductTriggerHandler.saveProductListViewDisplayConfig(
            'custom__testview',
            'Test View',
            true,
            new List<String>{ 'Name', 'ProductCode' },
            null,
            'all',
            'Name',
            'ASC'
        );

        Test.startTest();
        ProductTriggerHandler.deleteProductListViewDisplayConfig('custom__testview');
        Test.stopTest();

        for (ProductTriggerHandler.ListViewDisplayConfig cfg :
            ProductTriggerHandler.getProductListViewDisplayConfigs()) {
            System.assertNotEquals('custom__testview', cfg.viewKey);
        }
    }

    @IsTest
    static void testGetProductFamilyPicklistValues_returnsActiveValues() {
        Test.startTest();
        List<ProductTriggerHandler.ListViewPicklistOption> options =
            ProductTriggerHandler.getProductFamilyPicklistValues();
        Test.stopTest();

        System.assertNotEquals(null, options);
        for (ProductTriggerHandler.ListViewPicklistOption option : options) {
            System.assert(String.isNotBlank(option.label));
            System.assert(String.isNotBlank(option.value));
        }
    }

    @IsTest
    static void testGetProductListViewFieldOptions_returnsAccessibleFields() {
        Test.startTest();
        List<ProductTriggerHandler.ListViewFieldOption> options =
            ProductTriggerHandler.getProductListViewFieldOptions();
        Test.stopTest();

        System.assertNotEquals(null, options);
        System.assert(!options.isEmpty(), 'Expected accessible Product2 fields');
        Boolean hasName = false;
        for (ProductTriggerHandler.ListViewFieldOption option : options) {
            if ('Name'.equals(option.apiName)) {
                hasName = true;
                break;
            }
        }
        System.assert(hasName, 'Field picker should include Product Name');
    }

    @IsTest
    static void testGetProductListViews_returnsOptions() {
        Test.startTest();
        List<ProductTriggerHandler.ListViewOption> options =
            ProductTriggerHandler.getProductListViews();
        Test.stopTest();

        System.assertNotEquals(null, options);
        System.assert(!options.isEmpty(), 'Expected at least one list view option');
    }

    @IsTest
    static void testSearchProductsForListView_returnsMatches() {
        setupStandardPricebook();
        insert buildTestProduct('List View Search Widget', 'LV-SEARCH-1');

        Test.startTest();
        ProductTriggerHandler.ListViewSearchResult result =
            ProductTriggerHandler.searchProductsForListView(
                'List View Search Widget',
                50,
                1,
                'Name',
                'ASC',
                null,
                null,
                'all',
                null,
                null
            );
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assert(result.totalCount >= 1, 'Expected at least one matching product');
        System.assert(!result.records.isEmpty(), 'Expected record rows');
        System.assertEquals(
            'List View Search Widget',
            result.records[0].fields.get('Name')
        );
    }

    @IsTest
    static void testBrowseProductsForListView_pagination() {
        setupStandardPricebook();
        List<Product2> products = new List<Product2>();
        for (Integer i = 0; i < 4; i++) {
            products.add(buildTestProduct('Browse Page Product ' + i, 'BRW-' + i));
        }
        insert products;

        Test.startTest();
        ProductTriggerHandler.ListViewSearchResult page1 =
            ProductTriggerHandler.browseProductsForListView(
                2,
                1,
                'Name',
                'ASC',
                null,
                null,
                'all',
                null,
                null
            );
        ProductTriggerHandler.ListViewSearchResult page2 =
            ProductTriggerHandler.browseProductsForListView(
                2,
                2,
                'Name',
                'ASC',
                null,
                null,
                'all',
                null,
                null
            );
        Test.stopTest();

        System.assertEquals(2, page1.records.size());
        System.assertEquals(2, page2.records.size());
        System.assert(page1.hasMore);
    }

    @IsTest
    static void testSearchProductsForListView_blankTermThrows() {
        Boolean threw = false;
        try {
            ProductTriggerHandler.searchProductsForListView(
                '',
                50,
                1,
                'Name',
                'ASC',
                null,
                null,
                'all',
                null,
                null
            );
        } catch (AuraHandledException ex) {
            threw = true;
        }
        System.assert(threw, 'Blank search term should throw AuraHandledException');
    }

    @IsTest
    static void testSearchProductsForListView_pagination() {
        setupStandardPricebook();
        List<Product2> products = new List<Product2>();
        for (Integer i = 0; i < 5; i++) {
            products.add(buildTestProduct('Paginated Search Product ' + i, 'PAGE-' + i));
        }
        insert products;

        Test.startTest();
        ProductTriggerHandler.ListViewSearchResult page1 =
            ProductTriggerHandler.searchProductsForListView(
                'Paginated Search',
                2,
                1,
                'Name',
                'ASC',
                null,
                null,
                'all',
                null,
                null
            );
        ProductTriggerHandler.ListViewSearchResult page2 =
            ProductTriggerHandler.searchProductsForListView(
                'Paginated Search',
                2,
                2,
                'Name',
                'ASC',
                null,
                null,
                'all',
                null,
                null
            );
        Test.stopTest();

        System.assertEquals(5, page1.totalCount);
        System.assert(page1.hasMore, 'First page should indicate more results');
        System.assertEquals(2, page1.records.size());
        System.assertEquals(2, page2.records.size());
    }

    @IsTest
    static void testBrowseProductsForListView_cursorPagination_nullSortValueAsc() {
        setupStandardPricebook();
        List<Product2> products = new List<Product2>();
        for (Integer i = 0; i < 3; i++) {
            Product2 row = buildTestProduct(
                'Null Cost Cursor Product ' + i,
                'NCC-' + i
            );
            row.put('faxa__Purchase_Cost__c', null);
            products.add(row);
        }
        insert products;

        Test.startTest();
        ProductTriggerHandler.ListViewSearchResult page1 =
            ProductTriggerHandler.browseProductsForListView(
                2,
                1,
                'faxa__Purchase_Cost__c',
                'ASC',
                new List<String>{ 'Name', 'ProductCode', 'faxa__Purchase_Cost__c' },
                null,
                'all',
                null,
                null
            );
        ProductTriggerHandler.ListViewProductRow lastRow = page1.records[page1.records.size() - 1];
        ProductTriggerHandler.ListViewSearchResult page2 =
            ProductTriggerHandler.browseProductsForListView(
                2,
                1,
                'faxa__Purchase_Cost__c',
                'ASC',
                new List<String>{ 'Name', 'ProductCode', 'faxa__Purchase_Cost__c' },
                null,
                'all',
                lastRow.id,
                ''
            );
        Test.stopTest();

        System.assertEquals(2, page1.records.size(), 'First cursor page should return two rows');
        System.assert(
            page2.records.size() >= 1,
            'Null sort cursor should load the next page without invalid operator errors'
        );
    }

    @IsTest
    static void testBrowseProductsForListView_cursorPagination_mixedCostAsc() {
        setupStandardPricebook();
        List<Product2> products = new List<Product2>{
            buildTestProduct('Mixed Cost A', 'MIX-A'),
            buildTestProduct('Mixed Cost B', 'MIX-B'),
            buildTestProduct('Mixed Cost C', 'MIX-C')
        };
        products[0].put('faxa__Purchase_Cost__c', null);
        products[1].put('faxa__Purchase_Cost__c', 10);
        products[2].put('faxa__Purchase_Cost__c', 20);
        insert products;

        Test.startTest();
        ProductTriggerHandler.ListViewSearchResult page1 =
            ProductTriggerHandler.browseProductsForListView(
                2,
                1,
                'faxa__Purchase_Cost__c',
                'ASC',
                new List<String>{ 'Name', 'ProductCode', 'faxa__Purchase_Cost__c' },
                null,
                'all',
                null,
                null
            );
        ProductTriggerHandler.ListViewProductRow lastRow = page1.records[page1.records.size() - 1];
        Object lastCost = lastRow.fields.get('faxa__Purchase_Cost__c');
        String lastSortValue = lastCost == null ? '' : String.valueOf(lastCost);
        ProductTriggerHandler.ListViewSearchResult page2 =
            ProductTriggerHandler.browseProductsForListView(
                2,
                1,
                'faxa__Purchase_Cost__c',
                'ASC',
                new List<String>{ 'Name', 'ProductCode', 'faxa__Purchase_Cost__c' },
                null,
                'all',
                lastRow.id,
                lastSortValue
            );
        Test.stopTest();

        System.assertEquals(2, page1.records.size());
        System.assert(
            page2.records.size() >= 1,
            'Mixed null and numeric cost values should paginate across cursor boundaries'
        );
    }

    @IsTest
    static void testBrowseProductsForListView_cursorPagination_nullSortValueDesc() {
        setupStandardPricebook();
        List<Product2> products = new List<Product2>();
        for (Integer i = 0; i < 3; i++) {
            Product2 row = buildTestProduct(
                'Null Cost Desc Product ' + i,
                'NCD-' + i
            );
            row.put('faxa__Purchase_Cost__c', null);
            products.add(row);
        }
        insert products;

        Test.startTest();
        ProductTriggerHandler.ListViewSearchResult page1 =
            ProductTriggerHandler.browseProductsForListView(
                2,
                1,
                'faxa__Purchase_Cost__c',
                'DESC',
                new List<String>{ 'Name', 'ProductCode', 'faxa__Purchase_Cost__c' },
                null,
                'all',
                null,
                null
            );
        ProductTriggerHandler.ListViewProductRow lastRow = page1.records[page1.records.size() - 1];
        ProductTriggerHandler.ListViewSearchResult page2 =
            ProductTriggerHandler.browseProductsForListView(
                2,
                1,
                'faxa__Purchase_Cost__c',
                'DESC',
                new List<String>{ 'Name', 'ProductCode', 'faxa__Purchase_Cost__c' },
                null,
                'all',
                lastRow.id,
                ''
            );
        Test.stopTest();

        System.assertEquals(2, page1.records.size());
        System.assert(
            page2.records.size() >= 1,
            'Descending null sort cursor should not throw invalid operator'
        );
    }

    @IsTest
    static void testBrowseProductsForListView_cursorPagination_faxCostFieldAsc() {
        setupStandardPricebook();
        List<Product2> products = new List<Product2>{
            buildTestProduct('Fax Cost Null', 'FCN-1'),
            buildTestProduct('Fax Cost Ten', 'FCN-2'),
            buildTestProduct('Fax Cost Twenty', 'FCN-3')
        };
        products[0].put('fax__Cost__c', null);
        products[1].put('fax__Cost__c', 10);
        products[2].put('fax__Cost__c', 20);
        insert products;

        Test.startTest();
        ProductTriggerHandler.ListViewSearchResult page1 =
            ProductTriggerHandler.browseProductsForListView(
                2,
                1,
                'fax__Cost__c',
                'ASC',
                new List<String>{ 'Name', 'ProductCode', 'fax__Cost__c' },
                null,
                'all',
                null,
                null
            );
        ProductTriggerHandler.ListViewProductRow lastRow = page1.records[page1.records.size() - 1];
        Object lastCost = lastRow.fields.get('fax__Cost__c');
        String lastSortValue = lastCost == null ? null : String.valueOf(lastCost);
        ProductTriggerHandler.ListViewSearchResult page2 =
            ProductTriggerHandler.browseProductsForListView(
                2,
                1,
                'fax__Cost__c',
                'ASC',
                new List<String>{ 'Name', 'ProductCode', 'fax__Cost__c' },
                null,
                'all',
                lastRow.id,
                lastSortValue
            );
        Test.stopTest();

        System.assertEquals(2, page1.records.size());
        System.assert(
            page2.records.size() >= 1,
            'fax__Cost__c cursor pagination should not produce missing value at OR errors'
        );
    }

    @IsTest
    static void testBrowseProductsForListView_cursorPagination_numericCostValueAsc() {
        setupStandardPricebook();
        List<Product2> products = new List<Product2>{
            buildTestProduct('Numeric Cost 10', 'NC-10'),
            buildTestProduct('Numeric Cost 20', 'NC-20'),
            buildTestProduct('Numeric Cost 30', 'NC-30')
        };
        products[0].put('fax__Cost__c', 10);
        products[1].put('fax__Cost__c', 20);
        products[2].put('fax__Cost__c', 30);
        insert products;

        Test.startTest();
        ProductTriggerHandler.ListViewSearchResult page1 =
            ProductTriggerHandler.browseProductsForListView(
                2,
                1,
                'fax__Cost__c',
                'ASC',
                new List<String>{ 'Name', 'ProductCode', 'fax__Cost__c' },
                null,
                'all',
                null,
                null
            );
        ProductTriggerHandler.ListViewProductRow lastRow = page1.records[page1.records.size() - 1];
        ProductTriggerHandler.ListViewSearchResult page2 =
            ProductTriggerHandler.browseProductsForListView(
                2,
                1,
                'fax__Cost__c',
                'ASC',
                new List<String>{ 'Name', 'ProductCode', 'fax__Cost__c' },
                null,
                'all',
                lastRow.id,
                String.valueOf(lastRow.fields.get('fax__Cost__c'))
            );
        Test.stopTest();

        System.assertEquals(2, page1.records.size());
        System.assertEquals(
            1,
            page2.records.size(),
            'Numeric cost cursor should return the next sorted row'
        );
    }

    @IsTest
    static void testUpdateProductsForListView_success() {
        Product2 prod = buildTestProduct('List View Update Product', 'LV-UPD-1');
        insert prod;

        Test.startTest();
        ProductTriggerHandler.ListViewSaveResult result =
            ProductTriggerHandler.updateProductsForListView(
                new List<Map<String, Object>>{
                    new Map<String, Object>{
                        'Id' => prod.Id,
                        'Description' => 'Updated from list view'
                    }
                }
            );
        Test.stopTest();

        System.assertEquals(1, result.successCount);
        System.assertEquals(0, result.errors.size());
        Product2 updated = [SELECT Description FROM Product2 WHERE Id = :prod.Id];
        System.assertEquals('Updated from list view', updated.Description);
    }

    @IsTest
    static void testUpdateProductsForListView_emptyDraft() {
        ProductTriggerHandler.ListViewSaveResult result =
            ProductTriggerHandler.updateProductsForListView(null);
        System.assertEquals(0, result.successCount);
        System.assertEquals(0, result.errors.size());
    }

    @IsTest
    static void testUpdateProductsForListView_missingId() {
        ProductTriggerHandler.ListViewSaveResult result =
            ProductTriggerHandler.updateProductsForListView(
                new List<Map<String, Object>>{
                    new Map<String, Object>{ 'Description' => 'No Id row' }
                }
            );
        System.assertEquals(0, result.successCount);
        System.assertEquals(1, result.errors.size());
        System.assertEquals('Missing record Id.', result.errors[0].message);
    }

    @IsTest
    static void testUpdateProductsForListView_invalidField() {
        Product2 prod = buildTestProduct('Invalid Field Product', 'LV-INV-1');
        insert prod;

        ProductTriggerHandler.ListViewSaveResult result =
            ProductTriggerHandler.updateProductsForListView(
                new List<Map<String, Object>>{
                    new Map<String, Object>{
                        'Id' => prod.Id,
                        'NotARealField__c' => 'value'
                    }
                }
            );
        System.assertEquals(0, result.successCount);
        System.assertEquals(1, result.errors.size());
        System.assert(result.errors[0].message.contains('permission'));
    }

    @IsTest
    static void testUpdateProductsForListView_tooManyRows() {
        List<Map<String, Object>> drafts = new List<Map<String, Object>>();
        for (Integer i = 0; i < 201; i++) {
            drafts.add(new Map<String, Object>{ 'Id' => UserInfo.getUserId() });
        }
        Boolean threw = false;
        try {
            ProductTriggerHandler.updateProductsForListView(drafts);
        } catch (AuraHandledException ex) {
            threw = true;
        }
        System.assert(threw, 'More than 200 rows should throw AuraHandledException');
    }

    @IsTest
    static void testSaveDisplayConfig_blankKeyThrows() {
        Boolean threw = false;
        try {
            ProductTriggerHandler.saveProductListViewDisplayConfig(
                '',
                'Label',
                false,
                new List<String>{ 'Name' },
                null,
                'all',
                'Name',
                'ASC'
            );
        } catch (AuraHandledException ex) {
            threw = true;
        }
        System.assert(threw, 'Blank view key should throw');
    }

    @IsTest
    static void testDeleteDisplayConfig_nonCustomThrows() {
        ProductTriggerHandler.saveProductListViewDisplayConfig(
            'AllProducts',
            'All Products',
            false,
            new List<String>{ 'Name', 'ProductCode' },
            null,
            'all',
            'Name',
            'ASC'
        );
        Boolean threw = false;
        try {
            ProductTriggerHandler.deleteProductListViewDisplayConfig('AllProducts');
        } catch (AuraHandledException ex) {
            threw = true;
        }
        System.assert(threw, 'Deleting non-custom view should throw');
    }

    @IsTest
    static void testDeleteDisplayConfig_blankKeyThrows() {
        Boolean threw = false;
        try {
            ProductTriggerHandler.deleteProductListViewDisplayConfig('');
        } catch (AuraHandledException ex) {
            threw = true;
        }
        System.assert(threw, 'Blank view key should throw on delete');
    }

    @IsTest
    static void testBrowseProductsForListView_familyAndActiveFilters() {
        setupStandardPricebook();
        Product2 prod = buildTestProduct('Filtered Browse Product', 'FILT-1');
        insert prod;

        String familyFilter = null;
        for (ProductTriggerHandler.ListViewPicklistOption option :
            ProductTriggerHandler.getProductFamilyPicklistValues()) {
            if ('Hardware'.equalsIgnoreCase(option.value)) {
                familyFilter = option.value;
                break;
            }
        }

        Test.startTest();
        ProductTriggerHandler.ListViewSearchResult result =
            ProductTriggerHandler.browseProductsForListView(
                50,
                1,
                'Name',
                'ASC',
                new List<String>{ 'Name', 'Family', 'IsActive' },
                familyFilter,
                'active',
                null,
                null
            );
        Test.stopTest();

        System.assert(result.totalCount >= 1);
        for (ProductTriggerHandler.ListViewProductRow row : result.records) {
            if (familyFilter != null) {
                System.assertEquals(familyFilter, row.fields.get('Family'));
            }
            System.assertEquals(true, row.fields.get('IsActive'));
        }
    }

    @IsTest
    static void testBrowseProductsForListView_invalidFamilyThrows() {
        Boolean threw = false;
        try {
            ProductTriggerHandler.browseProductsForListView(
                50,
                1,
                'Name',
                'ASC',
                null,
                'NotAValidFamily',
                'all',
                null,
                null
            );
        } catch (AuraHandledException ex) {
            threw = true;
        }
        System.assert(threw, 'Invalid family filter should throw');
    }

    @IsTest
    static void testSearchProductsForListView_shortTerm() {
        setupStandardPricebook();
        insert buildTestProduct('X Short Search', 'XS-1');

        Test.startTest();
        ProductTriggerHandler.ListViewSearchResult result =
            ProductTriggerHandler.searchProductsForListView(
                'X',
                50,
                1,
                'Name',
                'ASC',
                null,
                null,
                'all',
                null,
                null
            );
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assert(result.totalCount >= 1);
    }

    @IsTest
    static void testSearchProductsForListView_termTooLong() {
        Boolean threw = false;
        try {
            ProductTriggerHandler.searchProductsForListView(
                'x'.repeat(256),
                50,
                1,
                'Name',
                'ASC',
                null,
                null,
                'all',
                null,
                null
            );
        } catch (AuraHandledException ex) {
            threw = true;
        }
        System.assert(threw, 'Search term over 255 chars should throw');
    }

    @IsTest
    static void testUpdateCostOnlyUpdatesPricebook() {
        Id standardPricebookId = setupStandardPricebook();
        Product2 productRecord = buildTestProduct('Cost Only Update');
        productRecord.put('faxa__Sales_Price__c', 100);
        productRecord.put('faxa__Purchase_Cost__c', 40);
        insert productRecord;

        productRecord.put('faxa__Purchase_Cost__c', 55);

        Test.startTest();
        update productRecord;
        Test.stopTest();

        PricebookEntry pbe = [
            SELECT Cost__c
            FROM PricebookEntry
            WHERE Product2Id = :productRecord.Id
            AND Pricebook2Id = :standardPricebookId
            LIMIT 1
        ];
        System.assertEquals(55, (Decimal) pbe.get('Cost__c'));
    }

    @IsTest
    static void testBrowseProductsForListView_descSortAndPageSizeNormalization() {
        setupStandardPricebook();
        insert buildTestProduct('Desc Sort Product Z', 'DESC-Z');
        insert buildTestProduct('Desc Sort Product A', 'DESC-A');

        Test.startTest();
        ProductTriggerHandler.ListViewSearchResult result =
            ProductTriggerHandler.browseProductsForListView(
                null,
                1,
                'Name',
                'DESC',
                new List<String>{ 'Name', 'ProductCode' },
                null,
                'all',
                null,
                null
            );
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals(50, result.pageSize, 'Null page size should default to 50');
        System.assert(!result.records.isEmpty());
    }

    @IsTest
    static void testSaveDisplayConfig_normalizesActiveFilter() {
        Test.startTest();
        ProductTriggerHandler.ListViewDisplayConfig saved =
            ProductTriggerHandler.saveProductListViewDisplayConfig(
                'custom__activefilter',
                'Active Filter View',
                true,
                new List<String>{ 'Name', 'ProductCode' },
                null,
                'inactive',
                'Name',
                'DESC'
            );
        Test.stopTest();

        System.assertEquals('inactive', saved.activeFilter);
        System.assertEquals('DESC', saved.sortDirection);
    }

    @IsTest
    static void testStandardPricebookInactiveGetsActivated() {
        Id standardPricebookId = Test.getStandardPricebookId();
        update new Pricebook2(Id = standardPricebookId, IsActive = false);

        Product2 productRecord = buildTestProduct('Inactive Pricebook Test', 'IPB-1');
        productRecord.put('faxa__Sales_Price__c', 88.88);

        Test.startTest();
        insert productRecord;
        Test.stopTest();

        Pricebook2 stdPb = [SELECT IsActive FROM Pricebook2 WHERE Id = :standardPricebookId];
        System.assertEquals(true, stdPb.IsActive, 'Standard pricebook should be activated');
    }

    @IsTest
    static void testUpdateNoPricebookChangeWhenPriceUnchanged() {
        setupStandardPricebook();
        Product2 productRecord = buildTestProduct('No PBE Change Test', 'NPC-1');
        productRecord.put('faxa__Sales_Price__c', 40);
        insert productRecord;

        PricebookEntry before = [
            SELECT UnitPrice FROM PricebookEntry WHERE Product2Id = :productRecord.Id LIMIT 1
        ];
        productRecord.Description = 'Only description changed';

        Test.startTest();
        update productRecord;
        Test.stopTest();

        PricebookEntry after = [
            SELECT UnitPrice FROM PricebookEntry WHERE Product2Id = :productRecord.Id LIMIT 1
        ];
        System.assertEquals(before.UnitPrice, after.UnitPrice);
    }

    @IsTest
    static void testInsertPriceWithoutPurchaseCost() {
        Id standardPricebookId = setupStandardPricebook();
        Product2 productRecord = buildTestProduct('No Cost Test', 'NC-1');
        productRecord.put('faxa__Sales_Price__c', 25);

        Test.startTest();
        insert productRecord;
        Test.stopTest();

        PricebookEntry pbe = [
            SELECT UnitPrice, Cost__c
            FROM PricebookEntry
            WHERE Product2Id = :productRecord.Id AND Pricebook2Id = :standardPricebookId
            LIMIT 1
        ];
        System.assertEquals(25, pbe.UnitPrice);
    }

    @IsTest
    static void testUpdateProductsForListView_invalidId() {
        ProductTriggerHandler.ListViewSaveResult result =
            ProductTriggerHandler.updateProductsForListView(
                new List<Map<String, Object>>{
                    new Map<String, Object>{
                        'Id' => 'not-a-valid-id',
                        'Description' => 'Should fail'
                    }
                }
            );
        System.assertEquals(0, result.successCount);
        System.assertEquals(1, result.errors.size());
        System.assertEquals('Invalid record Id.', result.errors[0].message);
    }

    @IsTest
    static void testUpdateProductsForListView_nonUpdateableField() {
        Product2 prod = buildTestProduct('Non Updateable Field', 'NUF-1');
        insert prod;

        ProductTriggerHandler.ListViewSaveResult result =
            ProductTriggerHandler.updateProductsForListView(
                new List<Map<String, Object>>{
                    new Map<String, Object>{
                        'Id' => prod.Id,
                        'CreatedDate' => Datetime.now()
                    }
                }
            );
        System.assertEquals(0, result.successCount);
        System.assertEquals(1, result.errors.size());
        System.assert(result.errors[0].fieldNames.contains('CreatedDate'));
    }

    @IsTest
    static void testUpdateProductsForListView_validationFailure() {
        Product2 prod = buildTestProduct('Validation Fail Product', 'VF-1');
        insert prod;

        ProductTriggerHandler.ListViewSaveResult result =
            ProductTriggerHandler.updateProductsForListView(
                new List<Map<String, Object>>{
                    new Map<String, Object>{
                        'Id' => prod.Id,
                        'Name' => ''
                    }
                }
            );
        System.assertEquals(0, result.successCount);
        System.assertEquals(1, result.errors.size());
        System.assertNotEquals(null, result.errors[0].recordId);
        System.assert(String.isNotBlank(result.errors[0].message));
    }

    @IsTest
    static void testUpdateProductsForListView_emptyList() {
        ProductTriggerHandler.ListViewSaveResult result =
            ProductTriggerHandler.updateProductsForListView(new List<Map<String, Object>>());
        System.assertEquals(0, result.successCount);
        System.assertEquals(0, result.errors.size());
    }

    @IsTest
    static void testDeleteDisplayConfig_missingKeyNoOp() {
        Test.startTest();
        ProductTriggerHandler.deleteProductListViewDisplayConfig('custom__doesnotexist');
        Test.stopTest();
        System.assert(true, 'Deleting a missing custom key should return without error');
    }

    @IsTest
    static void testBrowseProductsForListView_inactiveFilter() {
        setupStandardPricebook();
        Product2 inactiveProd = buildTestProduct('Inactive Browse Row', 'INACT-1');
        inactiveProd.IsActive = false;
        insert inactiveProd;

        Test.startTest();
        ProductTriggerHandler.ListViewSearchResult result =
            ProductTriggerHandler.browseProductsForListView(
                50,
                1,
                'Name',
                'ASC',
                new List<String>{ 'Name', 'IsActive' },
                null,
                'inactive',
                null,
                null
            );
        Test.stopTest();

        System.assert(result.totalCount >= 1);
        for (ProductTriggerHandler.ListViewProductRow row : result.records) {
            System.assertEquals(false, row.fields.get('IsActive'));
        }
    }

    @IsTest
    static void testSearchProductsForListView_inactiveFilter() {
        setupStandardPricebook();
        Product2 inactiveProd = buildTestProduct('Inactive Search Row', 'IS-1');
        inactiveProd.IsActive = false;
        insert inactiveProd;

        Test.startTest();
        ProductTriggerHandler.ListViewSearchResult result =
            ProductTriggerHandler.searchProductsForListView(
                'Inactive Search Row',
                50,
                1,
                'Name',
                'ASC',
                new List<String>{ 'Name', 'IsActive' },
                null,
                'inactive',
                null,
                null
            );
        Test.stopTest();

        System.assert(result.totalCount >= 1);
        System.assertEquals(false, result.records[0].fields.get('IsActive'));
    }

    @IsTest
    static void testBrowseProductsForListView_cursorPagination_descNumericCost() {
        setupStandardPricebook();
        List<Product2> products = new List<Product2>{
            buildTestProduct('Desc Cost 30', 'DC-30'),
            buildTestProduct('Desc Cost 20', 'DC-20'),
            buildTestProduct('Desc Cost 10', 'DC-10')
        };
        products[0].put('faxa__Purchase_Cost__c', 30);
        products[1].put('faxa__Purchase_Cost__c', 20);
        products[2].put('faxa__Purchase_Cost__c', 10);
        insert products;

        Test.startTest();
        ProductTriggerHandler.ListViewSearchResult page1 =
            ProductTriggerHandler.browseProductsForListView(
                2,
                1,
                'faxa__Purchase_Cost__c',
                'DESC',
                new List<String>{ 'Name', 'faxa__Purchase_Cost__c' },
                null,
                'all',
                null,
                null
            );
        ProductTriggerHandler.ListViewProductRow lastRow = page1.records[page1.records.size() - 1];
        ProductTriggerHandler.ListViewSearchResult page2 =
            ProductTriggerHandler.browseProductsForListView(
                2,
                1,
                'faxa__Purchase_Cost__c',
                'DESC',
                new List<String>{ 'Name', 'faxa__Purchase_Cost__c' },
                null,
                'all',
                lastRow.id,
                String.valueOf(lastRow.fields.get('faxa__Purchase_Cost__c'))
            );
        Test.stopTest();

        System.assertEquals(2, page1.records.size());
        System.assert(page2.records.size() >= 1);
    }

    @IsTest
    static void testBrowseProductsForListView_sortByIsActive() {
        setupStandardPricebook();
        insert buildTestProduct('Sort Active Product', 'SACT-1');

        Test.startTest();
        ProductTriggerHandler.ListViewSearchResult result =
            ProductTriggerHandler.browseProductsForListView(
                10,
                1,
                'IsActive',
                'ASC',
                new List<String>{ 'Name', 'IsActive' },
                null,
                'all',
                null,
                null
            );
        Test.stopTest();

        System.assert(!result.records.isEmpty());
    }

    @IsTest
    static void testDisplayConfig_loadFromTestStore() {
        ProductTriggerHandler.listViewConfigTestStore = new Map<String, Object>{
            'views' => new Map<String, Object>{
                'custom__stored' => new Map<String, Object>{
                    'viewLabel' => 'Stored View',
                    'isCustom' => true,
                    'selectedColumnFields' => new List<Object>{ 'Name', 'ProductCode' },
                    'familyFilter' => null,
                    'activeFilter' => 'all',
                    'sortField' => 'Name',
                    'sortDirection' => 'ASC'
                }
            }
        };

        Test.startTest();
        List<ProductTriggerHandler.ListViewDisplayConfig> configs =
            ProductTriggerHandler.getProductListViewDisplayConfigs();
        Test.stopTest();

        Boolean found = false;
        for (ProductTriggerHandler.ListViewDisplayConfig cfg : configs) {
            if ('custom__stored'.equals(cfg.viewKey)) {
                found = true;
                System.assertEquals('Stored View', cfg.viewLabel);
            }
        }
        System.assert(found, 'Expected config loaded from test store');
        ProductTriggerHandler.listViewConfigTestStore = null;
    }

    @IsTest
    static void testDisplayConfig_sanitizeAddsProductCode() {
        Test.startTest();
        ProductTriggerHandler.ListViewDisplayConfig saved =
            ProductTriggerHandler.saveProductListViewDisplayConfig(
                'custom__cols',
                'Columns Only Name',
                true,
                new List<String>{ 'Description', 'Family' },
                null,
                'all',
                'Name',
                'ASC'
            );
        Test.stopTest();

        System.assert(saved.selectedColumnFields.contains('Name'));
        System.assert(saved.selectedColumnFields.contains('ProductCode'));
    }

    @IsTest
    static void testBrowseProductsForListView_invalidDisplayFieldIgnored() {
        setupStandardPricebook();
        insert buildTestProduct('Invalid Display Field', 'IDF-1');

        Test.startTest();
        ProductTriggerHandler.ListViewSearchResult result =
            ProductTriggerHandler.browseProductsForListView(
                10,
                1,
                'Name',
                'ASC',
                new List<String>{ 'Name', 'NotARealField__c', 'ProductCode' },
                null,
                'all',
                null,
                null
            );
        Test.stopTest();

        System.assert(!result.records.isEmpty());
    }

    @IsTest
    static void testBrowseProductsForListView_largeOffsetReturnsCappedRows() {
        setupStandardPricebook();
        insert buildTestProduct('Large Offset Product', 'LOF-1');

        Test.startTest();
        ProductTriggerHandler.ListViewSearchResult result =
            ProductTriggerHandler.browseProductsForListView(
                200,
                11,
                'Name',
                'ASC',
                new List<String>{ 'Name', 'ProductCode' },
                null,
                'all',
                null,
                null
            );
        Test.stopTest();

        System.assertEquals(0, result.records.size());
        System.assertEquals(200, result.pageSize);
        System.assertEquals(false, result.hasMore);
    }

    @IsTest
    static void testBrowseProductsForListView_offsetTooLargeThrows() {
        Boolean threw = false;
        try {
            ProductTriggerHandler.browseProductsForListView(
                200,
                251,
                'Name',
                'ASC',
                null,
                null,
                'all',
                null,
                null
            );
        } catch (AuraHandledException ex) {
            threw = true;
        }
        System.assert(threw, 'Browse offsets of 50,000 rows or more should throw');
    }

    @IsTest
    static void testSearchProductsForListView_offsetTooLargeThrows() {
        Boolean threw = false;
        try {
            ProductTriggerHandler.searchProductsForListView(
                'Large Offset',
                200,
                251,
                'Name',
                'ASC',
                null,
                null,
                'all',
                null,
                null
            );
        } catch (AuraHandledException ex) {
            threw = true;
        }
        System.assert(threw, 'Search offsets of 50,000 rows or more should throw');
    }

    @IsTest
    static void testBrowseProductsForListView_cursorInvalidSortFallsBackToId() {
        setupStandardPricebook();
        List<Product2> products = new List<Product2>{
            buildTestProduct('Invalid Sort Cursor A', 'ISC-A'),
            buildTestProduct('Invalid Sort Cursor B', 'ISC-B')
        };
        insert products;

        Test.startTest();
        ProductTriggerHandler.ListViewSearchResult result =
            ProductTriggerHandler.browseProductsForListView(
                10,
                1,
                'NotARealField__c',
                'ASC',
                new List<String>{ 'Name', 'ProductCode' },
                null,
                'all',
                products[0].Id,
                'ignored'
            );
        Test.stopTest();

        System.assertNotEquals(null, result);
    }

    @IsTest
    static void testBrowseProductsForListView_cursorBooleanSort() {
        setupStandardPricebook();
        insert buildTestProduct('Boolean Cursor Active', 'BCA-1');

        Test.startTest();
        ProductTriggerHandler.ListViewSearchResult page1 =
            ProductTriggerHandler.browseProductsForListView(
                1,
                1,
                'IsActive',
                'ASC',
                new List<String>{ 'Name', 'IsActive' },
                null,
                'all',
                null,
                null
            );
        ProductTriggerHandler.ListViewProductRow lastRow = page1.records[page1.records.size() - 1];
        Boolean threw = false;
        try {
            ProductTriggerHandler.browseProductsForListView(
                1,
                1,
                'IsActive',
                'ASC',
                new List<String>{ 'Name', 'IsActive' },
                null,
                'all',
                lastRow.id,
                String.valueOf(lastRow.fields.get('IsActive'))
            );
        } catch (AuraHandledException ex) {
            threw = true;
        }
        Test.stopTest();

        System.assertEquals(1, page1.records.size());
        System.assert(threw, 'Boolean keyset comparison should surface as a handled query error');
    }

    @IsTest
    static void testBrowseProductsForListView_cursorCreatedDateSort() {
        setupStandardPricebook();
        insert new List<Product2>{
            buildTestProduct('Created Cursor A', 'CCA-1'),
            buildTestProduct('Created Cursor B', 'CCB-1')
        };

        Test.startTest();
        ProductTriggerHandler.ListViewSearchResult page1 =
            ProductTriggerHandler.browseProductsForListView(
                1,
                1,
                'CreatedDate',
                'ASC',
                new List<String>{ 'Name', 'CreatedDate' },
                null,
                'all',
                null,
                null
            );
        ProductTriggerHandler.ListViewProductRow lastRow = page1.records[page1.records.size() - 1];
        Boolean threw = false;
        try {
            ProductTriggerHandler.browseProductsForListView(
                1,
                1,
                'CreatedDate',
                'ASC',
                new List<String>{ 'Name', 'CreatedDate' },
                null,
                'all',
                lastRow.id,
                String.valueOf(lastRow.fields.get('CreatedDate'))
            );
        } catch (AuraHandledException ex) {
            threw = true;
        }
        Test.stopTest();

        System.assertEquals(1, page1.records.size());
        System.assert(threw, 'Datetime keyset literal should surface as a handled query error');
    }

    @IsTest
    static void testBrowseProductsForListView_cursorInvalidNumericSortValueAsc() {
        setupStandardPricebook();
        List<Product2> products = new List<Product2>{
            buildTestProduct('Invalid Numeric Cursor A', 'INCA-1'),
            buildTestProduct('Invalid Numeric Cursor B', 'INCB-1')
        };
        products[0].put('fax__Cost__c', 10);
        products[1].put('fax__Cost__c', 20);
        insert products;

        Test.startTest();
        ProductTriggerHandler.ListViewSearchResult result =
            ProductTriggerHandler.browseProductsForListView(
                10,
                1,
                'fax__Cost__c',
                'ASC',
                new List<String>{ 'Name', 'fax__Cost__c' },
                null,
                'all',
                products[0].Id,
                'not-a-number'
            );
        Test.stopTest();

        System.assert(!result.records.isEmpty());
    }

    @IsTest
    static void testBrowseProductsForListView_cursorInvalidNumericSortValueDesc() {
        setupStandardPricebook();
        List<Product2> products = new List<Product2>{
            buildTestProduct('Invalid Numeric Desc A', 'INDA-1'),
            buildTestProduct('Invalid Numeric Desc B', 'INDB-1')
        };
        products[0].put('fax__Cost__c', null);
        products[1].put('fax__Cost__c', null);
        insert products;

        Test.startTest();
        ProductTriggerHandler.ListViewSearchResult result =
            ProductTriggerHandler.browseProductsForListView(
                10,
                1,
                'fax__Cost__c',
                'DESC',
                new List<String>{ 'Name', 'fax__Cost__c' },
                null,
                'all',
                products[0].Id,
                'not-a-number'
            );
        Test.stopTest();

        System.assertNotEquals(null, result);
    }

    @IsTest
    static void testBrowseProductsForListView_reusesAdditionalDisplayFieldCache() {
        setupStandardPricebook();
        insert buildTestProduct('Additional Field Cache Product', 'AFC-1');

        Test.startTest();
        ProductTriggerHandler.browseProductsForListView(
            5,
            1,
            'Name',
            'ASC',
            null,
            null,
            'all',
            null,
            null
        );
        ProductTriggerHandler.ListViewSearchResult result =
            ProductTriggerHandler.browseProductsForListView(
                5,
                1,
                'Name',
                'ASC',
                null,
                null,
                'all',
                null,
                null
            );
        Test.stopTest();

        System.assert(!result.records.isEmpty());
    }

    @IsTest
    static void testDisplayConfig_readsContentVersionJson() {
        ProductTriggerHandler.listViewConfigTestStore = null;
        insert new ContentVersion(
            Title = 'ProductListView_DisplayConfig_v1',
            PathOnClient = 'product-list-view-config.json',
            VersionData = Blob.valueOf(
                '{"views":{"custom__file":{"viewLabel":"File View","isCustom":true,' +
                '"selectedColumnFields":["Name","ProductCode"],"familyFilter":null,' +
                '"activeFilter":"all","sortField":"Name","sortDirection":"ASC"}}}'
            )
        );

        Test.startTest();
        List<ProductTriggerHandler.ListViewDisplayConfig> configs =
            ProductTriggerHandler.getProductListViewDisplayConfigs();
        Test.stopTest();

        Boolean found = false;
        for (ProductTriggerHandler.ListViewDisplayConfig cfg : configs) {
            if ('custom__file'.equals(cfg.viewKey)) {
                found = true;
                System.assertEquals('File View', cfg.viewLabel);
            }
        }
        System.assert(found, 'Expected config to be read from ContentVersion JSON');
    }

    @IsTest
    static void testDisplayConfig_invalidContentVersionJsonReturnsEmpty() {
        ProductTriggerHandler.listViewConfigTestStore = null;
        insert new ContentVersion(
            Title = 'ProductListView_DisplayConfig_v1',
            PathOnClient = 'product-list-view-config.json',
            VersionData = Blob.valueOf('{not valid json')
        );

        Test.startTest();
        List<ProductTriggerHandler.ListViewDisplayConfig> configs =
            ProductTriggerHandler.getProductListViewDisplayConfigs();
        Test.stopTest();

        System.assertEquals(0, configs.size());
    }

    @IsTest
    static void testDisplayConfig_nonMapViewsReturnsEmpty() {
        ProductTriggerHandler.listViewConfigTestStore = null;
        insert new ContentVersion(
            Title = 'ProductListView_DisplayConfig_v1',
            PathOnClient = 'product-list-view-config.json',
            VersionData = Blob.valueOf('{"views":[]}')
        );

        Test.startTest();
        List<ProductTriggerHandler.ListViewDisplayConfig> configs =
            ProductTriggerHandler.getProductListViewDisplayConfigs();
        Test.stopTest();

        System.assertEquals(0, configs.size());
    }

    @IsTest
    static void testDisplayConfig_ignoresInvalidSelectedColumns() {
        Test.startTest();
        ProductTriggerHandler.ListViewDisplayConfig saved =
            ProductTriggerHandler.saveProductListViewDisplayConfig(
                'custom__invalidcols',
                'Invalid Columns',
                true,
                new List<String>{ 'NotARealField__c', 'Description' },
                null,
                'all',
                'Name',
                'ASC'
            );
        Test.stopTest();

        System.assert(!saved.selectedColumnFields.contains('NotARealField__c'));
        System.assert(saved.selectedColumnFields.contains('Description'));
    }

    @IsTest
    static void testUpdateProductsForListView_saveErrorUsesAttemptedFields() {
        Product2 deletedProd = buildTestProduct('Deleted List View Error', 'DLVE-1');
        insert deletedProd;
        delete deletedProd;

        ProductTriggerHandler.ListViewSaveResult result =
            ProductTriggerHandler.updateProductsForListView(
                new List<Map<String, Object>>{
                    new Map<String, Object>{
                        'Id' => deletedProd.Id,
                        'Description' => 'Deleted product update'
                    }
                }
            );

        System.assertEquals(0, result.successCount);
        System.assertEquals(1, result.errors.size());
        System.assert(result.errors[0].fieldNames.contains('Description'));
    }

    @IsTest
    static void testBrowseProductsForListView_usesFirstActiveFamilyFilter() {
        List<ProductTriggerHandler.ListViewPicklistOption> familyOptions =
            ProductTriggerHandler.getProductFamilyPicklistValues();
        String safeFamily = null;
        for (ProductTriggerHandler.ListViewPicklistOption option : familyOptions) {
            if (
                !'Inventory'.equalsIgnoreCase(option.value) &&
                !'Non-inventory'.equalsIgnoreCase(option.value) &&
                !'Service'.equalsIgnoreCase(option.value)
            ) {
                safeFamily = option.value;
                break;
            }
        }
        if (safeFamily == null) {
            System.assert(true, 'No non-validating Product Family value is available in this org');
            return;
        }

        setupStandardPricebook();
        Product2 prod = buildTestProduct('First Family Filter Product', 'FFF-1');
        prod.Family = safeFamily;
        insert prod;

        Test.startTest();
        ProductTriggerHandler.ListViewSearchResult result =
            ProductTriggerHandler.browseProductsForListView(
                10,
                1,
                'Name',
                'ASC',
                new List<String>{ 'Name', 'Family' },
                safeFamily,
                'all',
                null,
                null
            );
        Test.stopTest();

        System.assert(result.totalCount >= 1);
    }

    @IsTest
    static void testBrowseProductsForListView_stringCursorSort() {
        setupStandardPricebook();
        insert new List<Product2>{
            buildTestProduct('String Cursor Product A', 'SCP-A'),
            buildTestProduct('String Cursor Product B', 'SCP-B')
        };

        Test.startTest();
        ProductTriggerHandler.ListViewSearchResult page1 =
            ProductTriggerHandler.browseProductsForListView(
                1,
                1,
                'ProductCode',
                'ASC',
                new List<String>{ 'Name', 'ProductCode' },
                null,
                'all',
                null,
                null
            );
        ProductTriggerHandler.ListViewProductRow lastRow = page1.records[page1.records.size() - 1];
        ProductTriggerHandler.ListViewSearchResult page2 =
            ProductTriggerHandler.browseProductsForListView(
                1,
                1,
                'ProductCode',
                'ASC',
                new List<String>{ 'Name', 'ProductCode' },
                null,
                'all',
                lastRow.id,
                String.valueOf(lastRow.fields.get('ProductCode'))
            );
        Test.stopTest();

        System.assertEquals(1, page1.records.size());
        System.assertNotEquals(null, page2);
    }

    @IsTest
    static void testBrowseProductsForListView_blankSortAndCaseInsensitiveField() {
        setupStandardPricebook();
        insert buildTestProduct('Blank Sort Product', 'BSP-1');

        Test.startTest();
        ProductTriggerHandler.ListViewSearchResult result =
            ProductTriggerHandler.browseProductsForListView(
                10,
                1,
                '',
                'ASC',
                new List<String>{ '', 'name', 'ProductCode' },
                null,
                'all',
                null,
                null
            );
        Test.stopTest();

        System.assert(!result.records.isEmpty());
        System.assert(result.records[0].fields.containsKey('Name'));
    }

    @IsTest
    static void testSaveDisplayConfig_normalizesActiveFilterActive() {
        Test.startTest();
        ProductTriggerHandler.ListViewDisplayConfig saved =
            ProductTriggerHandler.saveProductListViewDisplayConfig(
                'custom__activeonly',
                'Active Only',
                true,
                new List<String>{ 'Name', 'ProductCode' },
                null,
                'active',
                'Name',
                'ASC'
            );
        Test.stopTest();

        System.assertEquals('active', saved.activeFilter);
    }

    @IsTest
    static void testSearchProductsForListView_queryExceptionHandled() {
        setupStandardPricebook();
        insert buildTestProduct('Search Boolean Cursor Product', 'SBC-1');

        ProductTriggerHandler.ListViewSearchResult page1 =
            ProductTriggerHandler.searchProductsForListView(
                'Search Boolean Cursor',
                1,
                1,
                'IsActive',
                'ASC',
                new List<String>{ 'Name', 'IsActive' },
                null,
                'all',
                null,
                null
            );

        Boolean threw = false;
        try {
            ProductTriggerHandler.searchProductsForListView(
                'Search Boolean Cursor',
                1,
                1,
                'IsActive',
                'ASC',
                new List<String>{ 'Name', 'IsActive' },
                null,
                'all',
                page1.records[page1.records.size() - 1].id,
                String.valueOf(page1.records[page1.records.size() - 1].fields.get('IsActive'))
            );
        } catch (AuraHandledException ex) {
            threw = true;
        }

        System.assert(threw, 'Search query exceptions should be wrapped for the LWC');
    }
}