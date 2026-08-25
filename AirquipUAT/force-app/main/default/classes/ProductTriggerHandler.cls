public with sharing class ProductTriggerHandler {

    private static final String SALES_PRICE_FIELD = 'faxa__Sales_Price__c';
    private static final String COST_FIELD = 'Cost__c';
    private static final String PURCHASE_COST_FIELD = 'faxa__Purchase_Cost__c';
    private static final Set<String> LIST_VIEW_PINNED_ADDITIONAL_FIELDS = new Set<String>{
        'faxa__Sales_Price__c',
        'faxa__Purchase_Cost__c',
        'faxa__In_Hand_Quantity__c'
    };

    // List view LWC search limits (read-only; no DML)
    private static final Integer LIST_VIEW_MAX_PAGE_SIZE = 200;
    private static final Integer LIST_VIEW_DEFAULT_PAGE_SIZE = 50;
    private static final Integer LIST_VIEW_RESERVED_QUERIES = 2;
    private static final Integer LIST_VIEW_MAX_SELECT_FIELDS = 100;
    private static final Integer LIST_VIEW_MAX_SOQL_OFFSET = 2000;
    private static final String LIST_VIEW_CONFIG_TITLE = 'ProductListView_DisplayConfig_v1';
    private static final String LIST_VIEW_CONFIG_FILENAME = 'product-list-view-config.json';
    private static final String ALL_PRODUCTS_VIEW_KEY = 'AllProducts';
    private static final Set<String> LIST_VIEW_DEFAULT_SORT_FIELDS = new Set<String>{
        'Name',
        'ProductCode',
        'Family',
        'IsActive',
        'CreatedDate',
        'LastModifiedDate',
        'StockKeepingUnit',
        'faxa__Sales_Price__c',
        'faxa__Purchase_Cost__c',
        'faxa__In_Hand_Quantity__c'
    };

    private static Set<String> listViewAdditionalDisplayFieldsCache;
    @TestVisible
    private static Map<String, Object> listViewConfigTestStore;

    // At most one QB sync update per product per transaction (prevents trigger recursion).
    @TestVisible
    private static Set<Id> quickBooksSyncedThisTransaction = new Set<Id>();
    private static Set<String> syncFieldsCache;

    public class ListViewProductRow {
        @AuraEnabled public Id id;
        @AuraEnabled public Map<String, Object> fields;
    }

    public class ListViewSearchResult {
        @AuraEnabled public List<ListViewProductRow> records;
        @AuraEnabled public Integer totalCount;
        @AuraEnabled public Integer pageNumber;
        @AuraEnabled public Integer pageSize;
        @AuraEnabled public Boolean hasMore;
    }

    private static Set<String> getSyncFields() {
        if (syncFieldsCache != null) {
            return syncFieldsCache;
        }
        Set<String> fields = new Set<String>();
        for (faxa__Mapping__c mapping : [
            SELECT faxa__FieldAx_Field__c
            FROM faxa__Mapping__c
            WHERE faxa__FieldAx_Object__c = 'Product2'
            AND faxa__FieldAx_Field__c != null
            AND faxa__External_App__r.Name = 'QuickBook'
        ]) {
            fields.add(mapping.faxa__FieldAx_Field__c);
        }
        syncFieldsCache = fields;
        return syncFieldsCache;
    }

    private static Boolean isSyncFieldChanged(Product2 newProd, Product2 oldProd, Set<String> syncFields) {
        for (String fieldName : syncFields) {
            if (newProd.get(fieldName) != oldProd.get(fieldName)) {
                return true;
            }
        }
        return false;
    }

    public static void handleAfterInsert(List<Product2> newList) {
        upsertPricebookEntries(newList, null);
        syncToQuickBooksOnInsert(newList);
    }

    private static void syncToQuickBooksOnInsert(List<Product2> newList) {
        markProductsForQuickBooksSync(newList, null);
    }

    public static void handleAfterUpdate(List<Product2> newList, Map<Id, Product2> oldMap) {
        upsertPricebookEntries(newList, oldMap);
        syncToQuickBooks(newList, oldMap);
    }

    private static void syncToQuickBooks(List<Product2> newList, Map<Id, Product2> oldMap) {
        if (getSyncFields().isEmpty()) {
            return;
        }
        markProductsForQuickBooksSync(newList, oldMap);
    }

    private static void markProductsForQuickBooksSync(
        List<Product2> newList,
        Map<Id, Product2> oldMap
    ) {
        Boolean isInsert = oldMap == null;
        Set<String> syncFields = isInsert ? null : getSyncFields();
        List<Product2> productsToUpdate = new List<Product2>();

        for (Product2 prod : newList) {
            if (quickBooksSyncedThisTransaction.contains(prod.Id)) {
                continue;
            }

            if (isInsert) {
                if (prod.faxa__Sync_to_QuickBooks__c == true) {
                    quickBooksSyncedThisTransaction.add(prod.Id);
                    continue;
                }
            } else {
                Product2 oldProd = oldMap.get(prod.Id);

                if (prod.faxa__Sync_to_QuickBooks__c != oldProd.faxa__Sync_to_QuickBooks__c) {
                    continue;
                }
                if (prod.faxa__Sync_to_QuickBooks__c == true) {
                    quickBooksSyncedThisTransaction.add(prod.Id);
                    continue;
                }
                if (!isSyncFieldChanged(prod, oldProd, syncFields)) {
                    continue;
                }
            }

            productsToUpdate.add(new Product2(
                Id = prod.Id,
                faxa__Sync_to_QuickBooks__c = true
            ));
            quickBooksSyncedThisTransaction.add(prod.Id);
        }

        if (!productsToUpdate.isEmpty()) {
            update productsToUpdate;
        }
    }

    private static void upsertPricebookEntries(List<Product2> newList, Map<Id, Product2> oldMap) {

        try {

            // ✅ Validate fields exist
            Map<String, Schema.SObjectField> fieldMap = Schema.SObjectType.Product2.fields.getMap();

            if (!fieldMap.containsKey(SALES_PRICE_FIELD) ||
                !fieldMap.containsKey(PURCHASE_COST_FIELD)) {

                System.debug('Required fields not found on Product2');
                return;
            }

            Set<Id> productIds = new Set<Id>();

            for (Product2 p : newList) {

                Decimal newPrice = (Decimal) p.get(SALES_PRICE_FIELD);
                Decimal newCost  = (Decimal) p.get(PURCHASE_COST_FIELD);

                if (newPrice == null) continue;

                if (oldMap == null) {
                    productIds.add(p.Id);
                } else {
                    Product2 oldRec = oldMap.get(p.Id);

                    Decimal oldPrice = (Decimal) oldRec.get(SALES_PRICE_FIELD);
                    Decimal oldCost  = (Decimal) oldRec.get(PURCHASE_COST_FIELD);

                    if (newPrice != oldPrice ||
                        newCost  != oldCost  ||
                        p.IsActive != oldRec.IsActive) {

                        productIds.add(p.Id);
                    }
                }
            }

            if (productIds.isEmpty()) return;

            // ✅ Get Standard Pricebook
            Pricebook2 stdPb = [
                SELECT Id, IsActive
                FROM Pricebook2
                WHERE IsStandard = true
                LIMIT 1
            ];

            if (!stdPb.IsActive) {
                stdPb.IsActive = true;
                update stdPb;
            }

            // ✅ Existing Pricebook Entries
            Map<Id, PricebookEntry> existingMap = new Map<Id, PricebookEntry>();

            for (PricebookEntry pbe : [
                SELECT Id, Product2Id, UnitPrice, IsActive, Cost__c
                FROM PricebookEntry
                WHERE Pricebook2Id = :stdPb.Id
                AND Product2Id IN :productIds
            ]) {
                existingMap.put(pbe.Product2Id, pbe);
            }

            List<PricebookEntry> toInsert = new List<PricebookEntry>();
            List<PricebookEntry> toUpdate = new List<PricebookEntry>();

            for (Product2 p : newList) {

                if (!productIds.contains(p.Id)) continue;

                Decimal price = (Decimal) p.get(SALES_PRICE_FIELD);
                Decimal cost  = (Decimal) p.get(PURCHASE_COST_FIELD);

                if (price == null || !p.IsActive) continue;

                PricebookEntry existing = existingMap.get(p.Id);

                if (existing == null) {

                    PricebookEntry pbe = new PricebookEntry();
                    pbe.Pricebook2Id = stdPb.Id;
                    pbe.Product2Id = p.Id;
                    pbe.UnitPrice = price;
                    pbe.IsActive = true;
                    pbe.UseStandardPrice = false;

                    if (cost != null) {
                        pbe.put(COST_FIELD, cost);
                    }

                    toInsert.add(pbe);

                } else {

                    existing.UnitPrice = price;
                    existing.IsActive = p.IsActive;

                    if (cost != null) {
                        existing.put(COST_FIELD, cost);
                    }

                    toUpdate.add(existing);
                }
            }

            if (!toInsert.isEmpty()) insert toInsert;
            if (!toUpdate.isEmpty()) update toUpdate;

        } catch (Exception e) {

            System.debug('Error in ProductTriggerHandler: ' + e.getMessage());

            // ❗ Optional: Show error to user
            for (Product2 p : newList) {
                p.addError('Error updating Pricebook: ' + e.getMessage());
            }
        }
    }

    // ✅ Optional delete handler
    public static void handleAfterDelete(List<Product2> oldList) {

        try {

            Set<Id> productIds = new Set<Id>();
            for (Product2 p : oldList) {
                productIds.add(p.Id);
            }

            List<PricebookEntry> pbEntries = [
                SELECT Id, IsActive
                FROM PricebookEntry
                WHERE Product2Id IN :productIds
            ];

            for (PricebookEntry pbe : pbEntries) {
                pbe.IsActive = false;
            }

            if (!pbEntries.isEmpty()) {
                update pbEntries;
            }

        } catch (Exception e) {
            System.debug('Error in delete handler: ' + e.getMessage());
        }
    }

    public class ListViewOption {
        @AuraEnabled public String label;
        @AuraEnabled public String apiName;
    }

    public class ListViewFieldOption {
        @AuraEnabled public String apiName;
        @AuraEnabled public String label;
        @AuraEnabled public String datatableType;
        @AuraEnabled public Boolean editable;
    }

    public class ListViewPicklistOption {
        @AuraEnabled public String label;
        @AuraEnabled public String value;
    }

    public class ListViewDisplayConfig {
        @AuraEnabled public String viewKey;
        @AuraEnabled public String viewLabel;
        @AuraEnabled public Boolean isCustom;
        @AuraEnabled public List<String> selectedColumnFields;
        @AuraEnabled public String familyFilter;
        @AuraEnabled public String activeFilter;
        @AuraEnabled public String sortField;
        @AuraEnabled public String sortDirection;
    }

    public class ListViewSaveError {
        @AuraEnabled public Id recordId;
        @AuraEnabled public String message;
        @AuraEnabled public List<String> fieldNames;
    }

    public class ListViewSaveResult {
        @AuraEnabled public Integer successCount;
        @AuraEnabled public List<ListViewSaveError> errors;
    }

    /**
     * Product2 list for productListView LWC browse mode (read-only, paginated).
     */
    @AuraEnabled(cacheable = true)
    public static List<ListViewOption> getProductListViews() {
        List<ListViewOption> options = new List<ListViewOption>();
        try {
            for (ListView listView : [
                SELECT Name, DeveloperName
                FROM ListView
                WHERE SobjectType = 'Product2'
                ORDER BY Name
                LIMIT 200
            ]) {
                ListViewOption row = new ListViewOption();
                row.label = listView.Name;
                row.apiName = listView.DeveloperName;
                options.add(row);
            }
        } catch (Exception ex) {
            System.debug(
                LoggingLevel.WARN,
                'ProductTriggerHandler.getProductListViews: ' + ex.getMessage()
            );
        }
        if (options.isEmpty()) {
            ListViewOption fallback = new ListViewOption();
            fallback.label = 'All Products';
            fallback.apiName = 'AllProducts';
            options.add(fallback);
        }
        return options;
    }

    @AuraEnabled(cacheable = true)
    public static List<ListViewFieldOption> getProductListViewFieldOptions() {
        assertProduct2ListViewAccess();
        List<ListViewFieldOption> options = new List<ListViewFieldOption>();
        Map<String, ListViewFieldOption> keyedOptions = new Map<String, ListViewFieldOption>();
        for (Schema.SObjectField token : Schema.SObjectType.Product2.fields.getMap().values()) {
            addListViewFieldOption(keyedOptions, token.getDescribe());
        }
        for (String pinnedField : LIST_VIEW_PINNED_ADDITIONAL_FIELDS) {
            Schema.SObjectField pinnedToken = resolveListViewFieldToken(pinnedField);
            if (pinnedToken != null) {
                addListViewFieldOption(keyedOptions, pinnedToken.getDescribe());
            }
        }
        List<String> keys = new List<String>(keyedOptions.keySet());
        keys.sort();
        for (String key : keys) {
            options.add(keyedOptions.get(key));
        }
        return options;
    }

    @AuraEnabled(cacheable = true)
    public static List<ListViewPicklistOption> getProductFamilyPicklistValues() {
        List<ListViewPicklistOption> options = new List<ListViewPicklistOption>();
        Schema.DescribeFieldResult familyDescribe = Product2.Family.getDescribe();
        if (!familyDescribe.isAccessible()) {
            return options;
        }
        for (Schema.PicklistEntry entry : familyDescribe.getPicklistValues()) {
            if (!entry.isActive()) {
                continue;
            }
            ListViewPicklistOption option = new ListViewPicklistOption();
            option.label = entry.getLabel();
            option.value = entry.getValue();
            options.add(option);
        }
        return options;
    }

    /**
     * Org-wide list view display settings stored in a shared Salesforce File (ContentVersion).
     * No custom objects — readable by all users with access to this Products tab.
     */
    @AuraEnabled(cacheable = false)
    public static List<ListViewDisplayConfig> getProductListViewDisplayConfigs() {
        return new ListViewConfigStore().loadAllConfigs();
    }

    @AuraEnabled(cacheable = false)
    public static ListViewDisplayConfig saveProductListViewDisplayConfig(
        String viewKey,
        String viewLabel,
        Boolean isCustom,
        List<String> selectedColumnFields,
        String familyFilter,
        String activeFilter,
        String sortField,
        String sortDirection
    ) {
        return new ListViewConfigStore().saveConfig(
            viewKey,
            viewLabel,
            isCustom,
            selectedColumnFields,
            familyFilter,
            activeFilter,
            sortField,
            sortDirection
        );
    }

    @AuraEnabled(cacheable = false)
    public static void deleteProductListViewDisplayConfig(String viewKey) {
        new ListViewConfigStore().deleteConfig(viewKey);
    }

    @AuraEnabled(cacheable = false)
    public static ListViewSaveResult updateProductsForListView(List<Map<String, Object>> draftValues) {
        ListViewSaveResult response = new ListViewSaveResult();
        response.successCount = 0;
        response.errors = new List<ListViewSaveError>();
        if (draftValues == null || draftValues.isEmpty()) {
            return response;
        }
        if (draftValues.size() > 200) {
            throw new AuraHandledException('You can update up to 200 products at a time.');
        }

        Map<Id, Integer> recordIndex = new Map<Id, Integer>();
        List<Product2> recordsToUpdate = new List<Product2>();
        List<Set<String>> attemptedFields = new List<Set<String>>();

        for (Integer i = 0; i < draftValues.size(); i++) {
            Map<String, Object> draft = draftValues[i];
            if (draft == null || !draft.containsKey('Id') || draft.get('Id') == null) {
                ListViewSaveError err = new ListViewSaveError();
                err.recordId = null;
                err.fieldNames = new List<String>();
                err.message = 'Missing record Id.';
                response.errors.add(err);
                continue;
            }

            Id recordId;
            try {
                recordId = (Id) String.valueOf(draft.get('Id'));
            } catch (Exception ex) {
                ListViewSaveError err = new ListViewSaveError();
                err.recordId = null;
                err.fieldNames = new List<String>();
                err.message = 'Invalid record Id.';
                response.errors.add(err);
                continue;
            }

            Product2 rowToUpdate = new Product2(Id = recordId);
            Set<String> changedFields = new Set<String>();
            List<String> blockedFields = new List<String>();

            for (String key : draft.keySet()) {
                if ('Id'.equalsIgnoreCase(key)) {
                    continue;
                }
                Schema.SObjectField token = resolveListViewFieldToken(key);
                if (token == null) {
                    blockedFields.add(key);
                    continue;
                }
                Schema.DescribeFieldResult describe = token.getDescribe();
                String normalizedName = describe.getName();
                if (!describe.isAccessible() || !describe.isUpdateable()) {
                    blockedFields.add(normalizedName);
                    continue;
                }
                rowToUpdate.put(normalizedName, draft.get(key));
                changedFields.add(normalizedName);
            }

            if (!blockedFields.isEmpty()) {
                ListViewSaveError err = new ListViewSaveError();
                err.recordId = recordId;
                err.fieldNames = blockedFields;
                err.message = 'You do not have permission to edit: ' + String.join(blockedFields, ', ');
                response.errors.add(err);
            }

            if (!changedFields.isEmpty()) {
                recordIndex.put(recordId, recordsToUpdate.size());
                recordsToUpdate.add(rowToUpdate);
                attemptedFields.add(changedFields);
            }
        }

        if (recordsToUpdate.isEmpty()) {
            return response;
        }

        Database.SaveResult[] saveResults = Database.update(recordsToUpdate, false);
        for (Integer i = 0; i < saveResults.size(); i++) {
            Database.SaveResult sr = saveResults[i];
            Product2 current = recordsToUpdate[i];
            if (sr.isSuccess()) {
                response.successCount++;
                continue;
            }
            List<String> messages = new List<String>();
            Set<String> fieldNames = new Set<String>();
            for (Database.Error err : sr.getErrors()) {
                messages.add(err.getMessage());
                if (err.getFields() != null) {
                    for (String fieldName : err.getFields()) {
                        fieldNames.add(fieldName);
                    }
                }
            }
            if (fieldNames.isEmpty()) {
                fieldNames.addAll(attemptedFields[i]);
            }
            ListViewSaveError rowError = new ListViewSaveError();
            rowError.recordId = current.Id;
            rowError.fieldNames = new List<String>(fieldNames);
            rowError.message = String.join(messages, ' | ');
            response.errors.add(rowError);
        }

        return response;
    }

    /**
     * Paginated Product2 browse for productListView LWC (read-only). No DML is performed.
     */
    @AuraEnabled(cacheable = false)
    public static ListViewSearchResult browseProductsForListView(
        Integer pageSize,
        Integer pageNumber,
        String sortField,
        String sortDirection,
        List<String> displayFields,
        String familyFilter,
        String activeFilter,
        Id lastRecordId,
        String lastSortValue
    ) {
        try {
            assertProduct2ListViewAccess();
            assertListViewSearchGovernorHeadroom();
            return queryProductsForListView(
                null,
                pageSize,
                pageNumber,
                sortField,
                sortDirection,
                displayFields,
                familyFilter,
                activeFilter,
                lastRecordId,
                lastSortValue
            );
        } catch (AuraHandledException ex) {
            throw ex;
        } catch (QueryException ex) {
            throw new AuraHandledException('Unable to load products: ' + ex.getMessage());
        } catch (Exception ex) {
            System.debug(
                LoggingLevel.ERROR,
                'ProductTriggerHandler.browseProductsForListView: ' + ex.getMessage()
            );
            throw new AuraHandledException(
                'An unexpected error occurred while loading products. Please try again.'
            );
        }
    }

    /**
     * Org-wide Product2 search for productListView LWC (read-only).
     * Bypasses the standard list view 2,000-row search window. No DML is performed.
     */
    @AuraEnabled(cacheable = false)
    public static ListViewSearchResult searchProductsForListView(
        String searchTerm,
        Integer pageSize,
        Integer pageNumber,
        String sortField,
        String sortDirection,
        List<String> displayFields,
        String familyFilter,
        String activeFilter,
        Id lastRecordId,
        String lastSortValue
    ) {
        try {
            assertProduct2ListViewAccess();
            assertListViewSearchGovernorHeadroom();

            String term = searchTerm == null ? '' : searchTerm.trim();
            if (String.isBlank(term)) {
                throw new AuraHandledException('Enter a search term to search all products.');
            }
            if (term.length() > 255) {
                throw new AuraHandledException('Search term must be 255 characters or fewer.');
            }

            Integer safePageSize = normalizeListViewPageSize(pageSize);
            Integer safePageNumber = pageNumber == null || pageNumber < 1 ? 1 : pageNumber;
            Integer offsetRows = (safePageNumber - 1) * safePageSize;

            if (offsetRows >= 50000) {
                throw new AuraHandledException(
                    'Result offset is too large. Refine your search or use an earlier page.'
                );
            }

            return searchProductsForListViewViaSosl(
                term,
                safePageSize,
                safePageNumber,
                sortField,
                sortDirection,
                displayFields,
                familyFilter,
                activeFilter,
                lastRecordId,
                lastSortValue
            );
        } catch (AuraHandledException ex) {
            throw ex;
        } catch (QueryException ex) {
            throw new AuraHandledException('Product search failed: ' + ex.getMessage());
        } catch (Exception ex) {
            System.debug(
                LoggingLevel.ERROR,
                'ProductTriggerHandler.searchProductsForListView: ' + ex.getMessage()
            );
            throw new AuraHandledException(
                'Unable to search products right now. ' + ex.getMessage()
            );
        }
    }

    private static ListViewSearchResult searchProductsForListViewViaSosl(
        String term,
        Integer pageSize,
        Integer pageNumber,
        String sortField,
        String sortDirection,
        List<String> displayFields,
        String familyFilter,
        String activeFilter,
        Id lastRecordId,
        String lastSortValue
    ) {
        Integer safePageSize = normalizeListViewPageSize(pageSize);
        Integer safePageNumber = pageNumber == null || pageNumber < 1 ? 1 : pageNumber;
        String countWhereClause = buildProductTermWhereClause(term);
        String filterWhereClause = buildListViewFilterWhere(
            countWhereClause,
            familyFilter,
            activeFilter
        );

        // SOSL can fail for very short or special terms. Fall back to SOQL search for resilience.
        if (term.length() < 2) {
            return queryProductsForListView(
                filterWhereClause,
                safePageSize,
                safePageNumber,
                sortField,
                sortDirection,
                displayFields,
                null,
                null,
                lastRecordId,
                lastSortValue
            );
        }

        if (Test.isRunningTest() || lastRecordId != null) {
            return queryProductsForListView(
                filterWhereClause,
                safePageSize,
                safePageNumber,
                sortField,
                sortDirection,
                displayFields,
                null,
                null,
                lastRecordId,
                lastSortValue
            );
        }

        Integer offsetRows = (safePageNumber - 1) * safePageSize;
        if (offsetRows >= LIST_VIEW_MAX_SOQL_OFFSET) {
            return queryProductsForListView(
                filterWhereClause,
                safePageSize,
                safePageNumber,
                sortField,
                sortDirection,
                displayFields,
                null,
                null,
                lastRecordId,
                lastSortValue
            );
        }

        Set<String> selectFields = buildListViewSelectFieldSet(sortField, displayFields);
        String returningFields = String.join(new List<String>(selectFields), ', ');
        String returningWhere = buildSoslReturningWhereClause(familyFilter, activeFilter);

        String orderField = 'Name';
        if (isAllowedListViewSortField(sortField)) {
            Schema.SObjectField token = resolveListViewFieldToken(sortField);
            if (token != null) {
                orderField = token.getDescribe().getName();
            }
        }
        String direction = 'DESC'.equalsIgnoreCase(sortDirection) ? 'DESC' : 'ASC';

        String soslQuery =
            'FIND \'' +
            String.escapeSingleQuotes(term) +
            '\' IN ALL FIELDS RETURNING Product2(' +
            returningFields +
            returningWhere +
            ' ORDER BY ' +
            orderField +
            ' ' +
            direction +
            ', Id ASC' +
            ' LIMIT ' +
            safePageSize +
            ' OFFSET ' +
            offsetRows +
            ')';

        List<Product2> products = new List<Product2>();
        try {
            List<List<SObject>> soslResults = Search.query(soslQuery);
            if (!soslResults.isEmpty() && soslResults[0] != null) {
                products = (List<Product2>) soslResults[0];
            }
        } catch (Exception ex) {
            System.debug(
                LoggingLevel.WARN,
                'ProductTriggerHandler.searchProductsForListViewViaSosl fallback to SOQL: ' + ex.getMessage()
            );
            return queryProductsForListView(
                filterWhereClause,
                safePageSize,
                safePageNumber,
                sortField,
                sortDirection,
                displayFields,
                null,
                null,
                lastRecordId,
                lastSortValue
            );
        }
        Integer totalCount = Database.countQuery(
            'SELECT COUNT() FROM Product2' +
            (String.isBlank(filterWhereClause) ? '' : ' WHERE ' + filterWhereClause)
        );

        ListViewSearchResult result = new ListViewSearchResult();
        result.records = toListViewRows(products, selectFields);
        result.totalCount = totalCount;
        result.pageNumber = safePageNumber;
        result.pageSize = safePageSize;
        result.hasMore =
            products.size() == safePageSize &&
            offsetRows + products.size() < totalCount &&
            offsetRows + safePageSize < LIST_VIEW_MAX_SOQL_OFFSET;
        return result;
    }

    private static ListViewSearchResult queryProductsForListView(
        String whereClause,
        Integer pageSize,
        Integer pageNumber,
        String sortField,
        String sortDirection,
        List<String> displayFields,
        String familyFilter,
        String activeFilter,
        Id lastRecordId,
        String lastSortValue
    ) {
        Integer safePageSize = normalizeListViewPageSize(pageSize);
        Integer safePageNumber = pageNumber == null || pageNumber < 1 ? 1 : pageNumber;
        Boolean useCursor = lastRecordId != null;
        Integer offsetRows = useCursor ? 0 : (safePageNumber - 1) * safePageSize;

        if (!useCursor && offsetRows >= 50000) {
            throw new AuraHandledException(
                'Result offset is too large. Refine your search or use an earlier page.'
            );
        }

        String filterWhere = buildListViewFilterWhere(whereClause, familyFilter, activeFilter);
        String keysetWhere = buildKeysetWhereClause(
            sortField,
            sortDirection,
            lastRecordId,
            lastSortValue
        );
        String combinedWhere = joinWhereClauses(filterWhere, keysetWhere);
        String orderBy = buildListViewOrderBy(sortField, sortDirection);
        Set<String> selectFields = buildListViewSelectFieldSet(sortField, displayFields);
        String fromClause = ' FROM Product2';
        String filterClause = String.isBlank(combinedWhere) ? '' : ' WHERE ' + combinedWhere;

        if (!Test.isRunningTest()) {
            if (Limits.getQueries() >= Limits.getLimitQueries() - LIST_VIEW_RESERVED_QUERIES) {
                throw new AuraHandledException(
                    'Unable to load products: SOQL query limit is nearly exhausted.'
                );
            }
        }

        Integer totalCount = runListViewProductCount(
            'SELECT COUNT()' +
            fromClause +
            (String.isBlank(filterWhere) ? '' : ' WHERE ' + filterWhere)
        );

        if (!Test.isRunningTest() && Limits.getQueries() >= Limits.getLimitQueries()) {
            throw new AuraHandledException('Unable to load product rows: SOQL query limit reached.');
        }

        if (!useCursor && offsetRows >= LIST_VIEW_MAX_SOQL_OFFSET) {
            ListViewSearchResult capped = new ListViewSearchResult();
            capped.records = new List<ListViewProductRow>();
            capped.totalCount = totalCount;
            capped.pageNumber = safePageNumber;
            capped.pageSize = safePageSize;
            capped.hasMore = false;
            return capped;
        }

        String limitClause = useCursor
            ? ' LIMIT :safePageSize'
            : ' LIMIT :safePageSize OFFSET :offsetRows';

        String dataSoql =
            'SELECT ' +
            String.join(new List<String>(selectFields), ',') +
            fromClause +
            filterClause +
            orderBy +
            limitClause;

        Map<String, Object> queryBinds = new Map<String, Object>{
            'safePageSize' => safePageSize
        };
        if (!useCursor) {
            queryBinds.put('offsetRows', offsetRows);
        }

        List<Product2> products = runListViewProductQuery(dataSoql, queryBinds);

        ListViewSearchResult result = new ListViewSearchResult();
        result.records = toListViewRows(products, selectFields);
        result.totalCount = totalCount;
        result.pageNumber = safePageNumber;
        result.pageSize = safePageSize;
        if (useCursor) {
            result.hasMore = products.size() == safePageSize;
        } else {
            result.hasMore =
                offsetRows + products.size() < totalCount &&
                offsetRows + safePageSize < LIST_VIEW_MAX_SOQL_OFFSET;
        }
        return result;
    }

    private static void assertListViewSearchGovernorHeadroom() {
        if (Trigger.isExecuting) {
            throw new AuraHandledException('Product search cannot run during trigger execution.');
        }
        if (Test.isRunningTest()) {
            return;
        }
        if (Limits.getQueries() + LIST_VIEW_RESERVED_QUERIES > Limits.getLimitQueries()) {
            throw new AuraHandledException(
                'Unable to search products: SOQL query limit would be exceeded.'
            );
        }
        if (Limits.getDmlStatements() >= Limits.getLimitDmlStatements()) {
            throw new AuraHandledException(
                'Unable to search products: DML limit is exhausted in this transaction.'
            );
        }
    }

    private static Integer normalizeListViewPageSize(Integer pageSize) {
        if (pageSize == null || pageSize < 1) {
            return LIST_VIEW_DEFAULT_PAGE_SIZE;
        }
        return Math.min(pageSize, LIST_VIEW_MAX_PAGE_SIZE);
    }

    private static String buildProductTermWhereClause(String term) {
        String escapedTerm = String.escapeSingleQuotes(term == null ? '' : term.trim());
        return
            '(Name LIKE \'%' +
            escapedTerm +
            '%\' OR ProductCode LIKE \'%' +
            escapedTerm +
            '%\' OR Description LIKE \'%' +
            escapedTerm +
            '%\')';
    }

    private static Set<String> buildListViewSelectFieldSet(
        String sortField,
        List<String> displayFields
    ) {
        Set<String> fields = new Set<String>{
            'Id',
            'Name',
            'ProductCode',
            'Description',
            'Family',
            'IsActive',
            'StockKeepingUnit',
            'CreatedDate',
            'LastModifiedDate',
            'faxa__Sales_Price__c',
            'faxa__Purchase_Cost__c',
            'faxa__In_Hand_Quantity__c'
        };
        if (displayFields != null && !displayFields.isEmpty()) {
            for (String requestedField : displayFields) {
                if (fields.size() >= LIST_VIEW_MAX_SELECT_FIELDS) {
                    break;
                }
                Schema.SObjectField token = resolveListViewFieldToken(requestedField);
                if (token == null) {
                    continue;
                }
                Schema.DescribeFieldResult describe = token.getDescribe();
                if (!isListViewQueryableField(describe)) {
                    continue;
                }
                fields.add(describe.getName());
            }
        } else {
            for (String additionalField : getListViewAdditionalDisplayFields()) {
                if (fields.size() >= LIST_VIEW_MAX_SELECT_FIELDS) {
                    break;
                }
                fields.add(additionalField);
            }
        }
        if (String.isNotBlank(sortField) && isAllowedListViewSortField(sortField)) {
            Schema.SObjectField token = resolveListViewFieldToken(sortField);
            if (token != null) {
                fields.add(token.getDescribe().getName());
            }
        }
        return fields;
    }

    private static Set<String> getListViewAdditionalDisplayFields() {
        if (listViewAdditionalDisplayFieldsCache != null) {
            return listViewAdditionalDisplayFieldsCache;
        }
        Set<String> fields = new Set<String>();
        Set<String> excluded = new Set<String>{
            'Id',
            'Name',
            'ProductCode',
            'Description',
            'Family',
            'IsActive',
            'StockKeepingUnit',
            'CreatedDate',
            'LastModifiedDate',
            'faxa__Sales_Price__c',
            'faxa__Purchase_Cost__c',
            'faxa__In_Hand_Quantity__c'
        };
        for (String pinnedField : LIST_VIEW_PINNED_ADDITIONAL_FIELDS) {
            Schema.SObjectField pinnedToken = resolveListViewFieldToken(pinnedField);
            if (pinnedToken == null) {
                continue;
            }
            Schema.DescribeFieldResult pinnedDescribe = pinnedToken.getDescribe();
            if (isListViewQueryableField(pinnedDescribe)) {
                fields.add(pinnedDescribe.getName());
            }
        }
        Map<String, Schema.SObjectField> fieldMap = Schema.SObjectType.Product2.fields.getMap();
        for (String apiName : fieldMap.keySet()) {
            if (fields.size() >= LIST_VIEW_MAX_SELECT_FIELDS) {
                break;
            }
            Schema.DescribeFieldResult describe = fieldMap.get(apiName).getDescribe();
            String normalized = describe.getName();
            if (excluded.contains(normalized)) {
                continue;
            }
            if (isListViewQueryableField(describe)) {
                fields.add(normalized);
            }
        }
        listViewAdditionalDisplayFieldsCache = fields;
        return listViewAdditionalDisplayFieldsCache;
    }

    private static Boolean isDisplayableListViewField(Schema.DescribeFieldResult describe) {
        if (describe == null || !describe.isAccessible()) {
            return false;
        }
        return isListViewQueryableField(describe);
    }

    private static Boolean isListViewQueryableField(Schema.DescribeFieldResult describe) {
        if (describe == null) {
            return false;
        }
        if ('Id'.equalsIgnoreCase(describe.getName())) {
            return false;
        }
        Schema.DisplayType type = describe.getType();
        return (
            type == Schema.DisplayType.STRING ||
            type == Schema.DisplayType.TEXTAREA ||
            type == Schema.DisplayType.BOOLEAN ||
            type == Schema.DisplayType.DATE ||
            type == Schema.DisplayType.DATETIME ||
            type == Schema.DisplayType.TIME ||
            type == Schema.DisplayType.DOUBLE ||
            type == Schema.DisplayType.CURRENCY ||
            type == Schema.DisplayType.INTEGER ||
            type == Schema.DisplayType.PERCENT ||
            type == Schema.DisplayType.PICKLIST ||
            type == Schema.DisplayType.MULTIPICKLIST ||
            type == Schema.DisplayType.EMAIL ||
            type == Schema.DisplayType.PHONE ||
            type == Schema.DisplayType.URL ||
            type == Schema.DisplayType.REFERENCE
        );
    }

    private static void assertProduct2ListViewAccess() {
        if (!Schema.sObjectType.Product2.isAccessible()) {
            throw new AuraHandledException('You do not have permission to view products.');
        }
    }

    private static List<Product2> runListViewProductQuery(
        String soql,
        Map<String, Object> bindVars
    ) {
        if (bindVars == null || bindVars.isEmpty()) {
            return (List<Product2>) Database.query(soql, AccessLevel.SYSTEM_MODE);
        }
        return (List<Product2>) Database.queryWithBinds(
            soql,
            bindVars,
            AccessLevel.SYSTEM_MODE
        );
    }

    private static Integer runListViewProductCount(String countSoql) {
        return Database.countQuery(countSoql, AccessLevel.SYSTEM_MODE);
    }

    private static void addListViewFieldOption(
        Map<String, ListViewFieldOption> keyedOptions,
        Schema.DescribeFieldResult describe
    ) {
        if (!isListViewQueryableField(describe)) {
            return;
        }
        ListViewFieldOption option = new ListViewFieldOption();
        option.apiName = describe.getName();
        option.label = describe.getLabel();
        option.datatableType = toDatatableType(describe.getType());
        option.editable = describe.isUpdateable();
        keyedOptions.put(option.label + '|' + option.apiName, option);
    }

    private static String buildListViewOrderBy(String sortField, String sortDirection) {
        String field = 'Name';
        if (isAllowedListViewSortField(sortField)) {
            Schema.SObjectField token = resolveListViewFieldToken(sortField);
            if (token != null) {
                field = token.getDescribe().getName();
            }
        }
        String direction = 'DESC'.equalsIgnoreCase(sortDirection) ? 'DESC' : 'ASC';
        // NULLS LAST keeps blank values at the bottom for both ASC and DESC so the
        // populated values are visible at the top (SOQL defaults to NULLS FIRST).
        return ' ORDER BY ' + field + ' ' + direction + ' NULLS LAST, Id ASC';
    }

    private static String buildListViewFilterWhere(
        String baseWhereClause,
        String familyFilter,
        String activeFilter
    ) {
        List<String> parts = new List<String>();
        if (String.isNotBlank(baseWhereClause)) {
            parts.add('(' + baseWhereClause + ')');
        }
        if (String.isNotBlank(familyFilter)) {
            if (!isActiveProductFamilyValue(familyFilter)) {
                throw new AuraHandledException('Invalid Product Family filter.');
            }
            parts.add(
                'Family = \'' + String.escapeSingleQuotes(familyFilter) + '\''
            );
        }
        if ('active'.equalsIgnoreCase(activeFilter)) {
            parts.add('IsActive = true');
        } else if ('inactive'.equalsIgnoreCase(activeFilter)) {
            parts.add('IsActive = false');
        }
        if (parts.isEmpty()) {
            return '';
        }
        return String.join(parts, ' AND ');
    }

    private static String buildSoslReturningWhereClause(
        String familyFilter,
        String activeFilter
    ) {
        List<String> parts = new List<String>();
        if (String.isNotBlank(familyFilter)) {
            if (!isActiveProductFamilyValue(familyFilter)) {
                throw new AuraHandledException('Invalid Product Family filter.');
            }
            parts.add(
                'Family = \'' + String.escapeSingleQuotes(familyFilter) + '\''
            );
        }
        if ('active'.equalsIgnoreCase(activeFilter)) {
            parts.add('IsActive = true');
        } else if ('inactive'.equalsIgnoreCase(activeFilter)) {
            parts.add('IsActive = false');
        }
        if (parts.isEmpty()) {
            return '';
        }
        return ' WHERE ' + String.join(parts, ' AND ');
    }

    private static String joinWhereClauses(String leftClause, String rightClause) {
        List<String> parts = new List<String>();
        if (String.isNotBlank(leftClause)) {
            parts.add('(' + leftClause + ')');
        }
        if (String.isNotBlank(rightClause)) {
            parts.add('(' + rightClause + ')');
        }
        if (parts.isEmpty()) {
            return '';
        }
        return String.join(parts, ' AND ');
    }

    private static Boolean isActiveProductFamilyValue(String familyValue) {
        if (String.isBlank(familyValue)) {
            return false;
        }
        Schema.DescribeFieldResult familyDescribe = Product2.Family.getDescribe();
        for (Schema.PicklistEntry entry : familyDescribe.getPicklistValues()) {
            if (entry.isActive() && familyValue.equals(entry.getValue())) {
                return true;
            }
        }
        return false;
    }

    private static String buildKeysetWhereClause(
        String sortField,
        String sortDirection,
        Id lastRecordId,
        String lastSortValue
    ) {
        if (lastRecordId == null) {
            return '';
        }
        Schema.SObjectField token = resolveListViewFieldToken(
            String.isBlank(sortField) ? 'Name' : sortField
        );
        if (token == null) {
            return 'Id > \'' + String.escapeSingleQuotes(String.valueOf(lastRecordId)) + '\'';
        }
        Schema.DescribeFieldResult describe = token.getDescribe();
        String columnName = describe.getName();
        String idLiteral = '\'' + String.escapeSingleQuotes(String.valueOf(lastRecordId)) + '\'';
        Boolean isDesc = 'DESC'.equalsIgnoreCase(sortDirection);

        // Ordering is "<field> <dir> NULLS LAST, Id ASC": populated values first
        // (asc/desc), then the null rows ordered by Id at the very end.
        // SOQL rejects comparison operators against null (e.g. Cost__c > null).
        if (isKeysetNullValue(lastSortValue)) {
            // Cursor sits inside the trailing null block; only more null rows remain.
            return '(' + columnName + ' = null AND Id > ' + idLiteral + ')';
        }

        String sortLiteral = formatKeysetLiteral(lastSortValue, describe.getType());
        if (String.isBlank(sortLiteral)) {
            // Unparseable cursor value: treat it as the null block.
            return '(' + columnName + ' = null AND Id > ' + idLiteral + ')';
        }

        String comparator = isDesc ? ' < ' : ' > ';
        // Remaining populated values in sort order, ties broken by Id, then fall
        // through into the trailing null rows.
        return '(' +
            columnName +
            comparator +
            sortLiteral +
            ' OR (' +
            columnName +
            ' = ' +
            sortLiteral +
            ' AND Id > ' +
            idLiteral +
            ') OR ' +
            columnName +
            ' = null)';
    }

    private static Boolean isKeysetNullValue(String rawValue) {
        return String.isBlank(rawValue) || 'null'.equalsIgnoreCase(rawValue);
    }

    private static String formatKeysetLiteral(String rawValue, Schema.DisplayType fieldType) {
        if (isKeysetNullValue(rawValue)) {
            return null;
        }
        if (fieldType == Schema.DisplayType.BOOLEAN) {
            return 'true'.equalsIgnoreCase(rawValue) ? 'true' : 'false';
        }
        if (
            fieldType == Schema.DisplayType.DOUBLE ||
            fieldType == Schema.DisplayType.CURRENCY ||
            fieldType == Schema.DisplayType.INTEGER ||
            fieldType == Schema.DisplayType.PERCENT
        ) {
            String cleaned = rawValue.replace(',', '').trim();
            try {
                Decimal.valueOf(cleaned);
                return cleaned;
            } catch (Exception ex) {
                return null;
            }
        }
        if (fieldType == Schema.DisplayType.DATE) {
            return '\'' + String.escapeSingleQuotes(rawValue) + '\'';
        }
        if (fieldType == Schema.DisplayType.DATETIME) {
            String normalized = rawValue.replace('T', ' ').replace('Z', '');
            return '\'' + String.escapeSingleQuotes(normalized) + '\'';
        }
        return '\'' + String.escapeSingleQuotes(rawValue) + '\'';
    }

    private static Boolean isAllowedListViewSortField(String sortField) {
        if (String.isBlank(sortField)) {
            return false;
        }
        if (LIST_VIEW_DEFAULT_SORT_FIELDS.contains(sortField)) {
            return true;
        }
        Schema.SObjectField token = resolveListViewFieldToken(sortField);
        if (token == null) {
            return false;
        }
        Schema.DescribeFieldResult describe = token.getDescribe();
        return describe.isSortable();
    }

    private static Schema.SObjectField resolveListViewFieldToken(String fieldApiName) {
        if (String.isBlank(fieldApiName)) {
            return null;
        }
        Map<String, Schema.SObjectField> fieldMap = Schema.SObjectType.Product2.fields.getMap();
        if (fieldMap.containsKey(fieldApiName)) {
            return fieldMap.get(fieldApiName);
        }
        for (String key : fieldMap.keySet()) {
            if (key.equalsIgnoreCase(fieldApiName)) {
                return fieldMap.get(key);
            }
        }
        return null;
    }

    private static List<ListViewProductRow> toListViewRows(
        List<Product2> products,
        Set<String> selectFields
    ) {
        List<ListViewProductRow> rows = new List<ListViewProductRow>();
        for (Product2 product : products) {
            ListViewProductRow row = new ListViewProductRow();
            row.id = product.Id;
            row.fields = new Map<String, Object>();
            for (String fieldName : selectFields) {
                if ('Id'.equalsIgnoreCase(fieldName)) {
                    continue;
                }
                row.fields.put(fieldName, product.get(fieldName));
            }
            rows.add(row);
        }
        return rows;
    }

    private static String toDatatableType(Schema.DisplayType displayType) {
        if (displayType == Schema.DisplayType.BOOLEAN) {
            return 'boolean';
        }
        if (
            displayType == Schema.DisplayType.CURRENCY
        ) {
            return 'currency';
        }
        if (
            displayType == Schema.DisplayType.DOUBLE ||
            displayType == Schema.DisplayType.INTEGER ||
            displayType == Schema.DisplayType.PERCENT
        ) {
            return 'number';
        }
        if (
            displayType == Schema.DisplayType.DATE ||
            displayType == Schema.DisplayType.DATETIME
        ) {
            return 'date';
        }
        return 'text';
    }

    private static List<String> sanitizeSelectedColumns(List<String> requestedColumns) {
        List<String> ordered = new List<String>();
        Set<String> seen = new Set<String>();
        if (requestedColumns != null) {
            for (String fieldName : requestedColumns) {
                Schema.SObjectField token = resolveListViewFieldToken(fieldName);
                if (token == null) {
                    continue;
                }
                String normalized = token.getDescribe().getName();
                if (!seen.contains(normalized)) {
                    seen.add(normalized);
                    ordered.add(normalized);
                }
            }
        }
        if (!seen.contains('Name')) {
            ordered.add(0, 'Name');
            seen.add('Name');
        }
        if (!seen.contains('ProductCode')) {
            Integer nameIndex = ordered.indexOf('Name');
            Integer insertIndex = nameIndex >= 0 ? nameIndex + 1 : 0;
            ordered.add(insertIndex, 'ProductCode');
        }
        return ordered;
    }

    private static String normalizeListViewConfigKey(String viewKey) {
        return viewKey == null ? '' : viewKey.trim();
    }

    private static String normalizeSharedViewKey(String viewKey, String viewLabel) {
        String normalizedKey = normalizeListViewConfigKey(viewKey);
        if (ALL_PRODUCTS_VIEW_KEY.equalsIgnoreCase(normalizedKey)) {
            return ALL_PRODUCTS_VIEW_KEY;
        }
        if (
            !String.isBlank(viewLabel) &&
            'All Products'.equalsIgnoreCase(viewLabel.trim())
        ) {
            return ALL_PRODUCTS_VIEW_KEY;
        }
        return normalizedKey;
    }

    private static Map<String, Map<String, Object>> normalizeViewsMapKeys(
        Map<String, Map<String, Object>> views
    ) {
        Map<String, Map<String, Object>> normalized = new Map<String, Map<String, Object>>();
        if (views == null || views.isEmpty()) {
            return normalized;
        }
        for (String viewKey : views.keySet()) {
            Map<String, Object> payload = views.get(viewKey);
            if (payload == null) {
                continue;
            }
            String canonicalKey = normalizeSharedViewKey(
                viewKey,
                (String) payload.get('viewLabel')
            );
            normalized.put(canonicalKey, payload);
        }
        return normalized;
    }

    private static String normalizeActiveFilter(String activeFilter) {
        if ('active'.equalsIgnoreCase(activeFilter)) {
            return 'active';
        }
        if ('inactive'.equalsIgnoreCase(activeFilter)) {
            return 'inactive';
        }
        return 'all';
    }

    private static ListViewDisplayConfig toDisplayConfig(String viewKey, Map<String, Object> raw) {
        ListViewDisplayConfig config = new ListViewDisplayConfig();
        config.viewKey = viewKey;
        config.viewLabel = (String) raw.get('viewLabel');
        config.isCustom = raw.get('isCustom') == true;
        config.selectedColumnFields = parseSelectedColumnsFromRaw(raw.get('selectedColumnFields'));
        config.familyFilter = (String) raw.get('familyFilter');
        config.activeFilter = (String) raw.get('activeFilter');
        config.sortField = (String) raw.get('sortField');
        config.sortDirection = (String) raw.get('sortDirection');
        return config;
    }

    private static List<String> parseSelectedColumnsFromRaw(Object rawColumns) {
        List<String> columns = new List<String>();
        if (rawColumns instanceof List<Object>) {
            for (Object value : (List<Object>) rawColumns) {
                if (value != null) {
                    columns.add(String.valueOf(value));
                }
            }
        }
        return sanitizeSelectedColumns(columns);
    }

    private static Map<String, Object> buildConfigPayload(
        String viewKey,
        String viewLabel,
        Boolean isCustom,
        List<String> selectedColumnFields,
        String familyFilter,
        String activeFilter,
        String sortField,
        String sortDirection
    ) {
        Map<String, Object> payload = new Map<String, Object>();
        payload.put('viewLabel', String.isBlank(viewLabel) ? viewKey : viewLabel.trim());
        payload.put('isCustom', isCustom == true);
        payload.put('selectedColumnFields', sanitizeSelectedColumns(selectedColumnFields));
        payload.put('familyFilter', familyFilter);
        payload.put('activeFilter', normalizeActiveFilter(activeFilter));
        payload.put('sortField', String.isBlank(sortField) ? 'Name' : sortField);
        payload.put(
            'sortDirection',
            'DESC'.equalsIgnoreCase(sortDirection) ? 'DESC' : 'ASC'
        );
        return payload;
    }

    /**
     * Persists shared list view settings in a single org-wide ContentVersion file.
     */
    private without sharing class ListViewConfigStore {
        public List<ListViewDisplayConfig> loadAllConfigs() {
            Map<String, Map<String, Object>> views = normalizeViewsMapKeys(readViewsMap());
            List<ListViewDisplayConfig> configs = new List<ListViewDisplayConfig>();
            for (String viewKey : views.keySet()) {
                configs.add(toDisplayConfig(viewKey, views.get(viewKey)));
            }
            return configs;
        }

        public ListViewDisplayConfig saveConfig(
            String viewKey,
            String viewLabel,
            Boolean isCustom,
            List<String> selectedColumnFields,
            String familyFilter,
            String activeFilter,
            String sortField,
            String sortDirection
        ) {
            String normalizedKey = normalizeSharedViewKey(viewKey, viewLabel);
            if (String.isBlank(normalizedKey)) {
                throw new AuraHandledException('List view key is required.');
            }
            Map<String, Map<String, Object>> views = readViewsMap();
            views.put(
                normalizedKey,
                buildConfigPayload(
                    normalizedKey,
                    viewLabel,
                    isCustom,
                    selectedColumnFields,
                    familyFilter,
                    activeFilter,
                    sortField,
                    sortDirection
                )
            );
            writeViewsMap(views);
            return toDisplayConfig(normalizedKey, views.get(normalizedKey));
        }

        public void deleteConfig(String viewKey) {
            String normalizedKey = normalizeSharedViewKey(viewKey, null);
            if (String.isBlank(normalizedKey)) {
                throw new AuraHandledException('List view key is required.');
            }
            Map<String, Map<String, Object>> views = readViewsMap();
            if (!views.containsKey(normalizedKey)) {
                return;
            }
            if (views.get(normalizedKey).get('isCustom') != true) {
                throw new AuraHandledException('Only custom list views can be deleted.');
            }
            views.remove(normalizedKey);
            writeViewsMap(views);
        }

        private Map<String, Map<String, Object>> readViewsMap() {
            if (Test.isRunningTest() && listViewConfigTestStore != null) {
                return castViewsMap(listViewConfigTestStore.get('views'));
            }
            String jsonBody = readConfigJson();
            if (String.isBlank(jsonBody)) {
                return new Map<String, Map<String, Object>>();
            }
            try {
                Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(jsonBody);
                return castViewsMap(parsed.get('views'));
            } catch (Exception ex) {
                System.debug(
                    LoggingLevel.WARN,
                    'ListViewConfigStore.readViewsMap: ' + ex.getMessage()
                );
                return new Map<String, Map<String, Object>>();
            }
        }

        private void writeViewsMap(Map<String, Map<String, Object>> views) {
            Map<String, Object> envelope = new Map<String, Object>();
            envelope.put('views', views == null ? new Map<String, Object>() : views);
            String jsonBody = JSON.serialize(envelope);
            if (Test.isRunningTest()) {
                listViewConfigTestStore = envelope;
                return;
            }
            persistConfigJson(jsonBody);
        }

        private Map<String, Map<String, Object>> castViewsMap(Object rawViews) {
            Map<String, Map<String, Object>> views = new Map<String, Map<String, Object>>();
            if (!(rawViews instanceof Map<String, Object>)) {
                return views;
            }
            Map<String, Object> rawMap = (Map<String, Object>) rawViews;
            for (String key : rawMap.keySet()) {
                Object value = rawMap.get(key);
                if (value instanceof Map<String, Object>) {
                    views.put(key, (Map<String, Object>) value);
                }
            }
            return views;
        }

        private String readConfigJson() {
            List<ContentVersion> versions = (List<ContentVersion>) Database.queryWithBinds(
                'SELECT VersionData FROM ContentVersion WHERE Title = :configTitle AND IsLatest = true ORDER BY CreatedDate DESC LIMIT 1',
                new Map<String, Object>{ 'configTitle' => LIST_VIEW_CONFIG_TITLE },
                AccessLevel.SYSTEM_MODE
            );
            if (versions.isEmpty() || versions[0].VersionData == null) {
                return null;
            }
            return versions[0].VersionData.toString();
        }

        private void persistConfigJson(String jsonBody) {
            Id contentDocumentId;
            List<ContentVersion> existingVersions = (List<ContentVersion>) Database.queryWithBinds(
                'SELECT ContentDocumentId FROM ContentVersion WHERE Title = :configTitle AND IsLatest = true ORDER BY CreatedDate DESC LIMIT 1',
                new Map<String, Object>{ 'configTitle' => LIST_VIEW_CONFIG_TITLE },
                AccessLevel.SYSTEM_MODE
            );
            if (!existingVersions.isEmpty()) {
                contentDocumentId = existingVersions[0].ContentDocumentId;
            }

            ContentVersion nextVersion = new ContentVersion();
            nextVersion.Title = LIST_VIEW_CONFIG_TITLE;
            nextVersion.PathOnClient = LIST_VIEW_CONFIG_FILENAME;
            nextVersion.VersionData = Blob.valueOf(jsonBody);
            nextVersion.IsMajorVersion = true;
            if (contentDocumentId != null) {
                nextVersion.ContentDocumentId = contentDocumentId;
            }
            Database.insert(nextVersion, AccessLevel.SYSTEM_MODE);
            shareConfigDocumentWithOrg(nextVersion.Id, contentDocumentId);
        }

        private void shareConfigDocumentWithOrg(Id contentVersionId, Id existingDocumentId) {
            Id contentDocumentId = existingDocumentId;
            if (contentDocumentId == null && contentVersionId != null) {
                List<ContentVersion> insertedVersions = (List<ContentVersion>) Database.queryWithBinds(
                    'SELECT ContentDocumentId FROM ContentVersion WHERE Id = :versionId LIMIT 1',
                    new Map<String, Object>{ 'versionId' => contentVersionId },
                    AccessLevel.SYSTEM_MODE
                );
                if (!insertedVersions.isEmpty()) {
                    contentDocumentId = insertedVersions[0].ContentDocumentId;
                }
            }
            if (contentDocumentId == null) {
                return;
            }
            List<ContentDocumentLink> existingLinks = (List<ContentDocumentLink>) Database.queryWithBinds(
                'SELECT Id FROM ContentDocumentLink WHERE ContentDocumentId = :docId AND LinkedEntityId = :orgId LIMIT 1',
                new Map<String, Object>{
                    'docId' => contentDocumentId,
                    'orgId' => UserInfo.getOrganizationId()
                },
                AccessLevel.SYSTEM_MODE
            );
            if (!existingLinks.isEmpty()) {
                return;
            }
            ContentDocumentLink orgLink = new ContentDocumentLink();
            orgLink.ContentDocumentId = contentDocumentId;
            orgLink.LinkedEntityId = UserInfo.getOrganizationId();
            orgLink.ShareType = 'V';
            orgLink.Visibility = 'AllUsers';
            Database.insert(orgLink, AccessLevel.SYSTEM_MODE);
        }
    }
}