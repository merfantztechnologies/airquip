public with sharing class NewPurchaseOrderController {

    public class ProductOption {
        @AuraEnabled public String pricebookEntryId { get; set; }
        @AuraEnabled public String productId { get; set; }
        @AuraEnabled public String productName { get; set; }
        @AuraEnabled public String productCode { get; set; }
        @AuraEnabled public String quickBooksItemId { get; set; }
        @AuraEnabled public String description { get; set; }
        @AuraEnabled public Decimal unitPrice { get; set; }
        @AuraEnabled public Decimal cost { get; set; }
        @AuraEnabled public Boolean taxable { get; set; }
    }

    public class LineItemWrapper {
        @AuraEnabled public String key { get; set; }
        @AuraEnabled public String productId { get; set; }
        @AuraEnabled public String productName { get; set; }
        @AuraEnabled public String productCode { get; set; }
        @AuraEnabled public String quickBooksItemId { get; set; }
        @AuraEnabled public String description { get; set; }
        @AuraEnabled public Decimal quantity { get; set; }
        @AuraEnabled public Decimal rate { get; set; }
        @AuraEnabled public Decimal amount { get; set; }
        @AuraEnabled public String classId { get; set; }
        @AuraEnabled public String customerId { get; set; }
        @AuraEnabled public Boolean isDeleted { get; set; }
    }

    public class PurchaseOrderWrapper {
        @AuraEnabled public String poNumber { get; set; }
        @AuraEnabled public String vendorId { get; set; }
        @AuraEnabled public String poDate { get; set; }
        @AuraEnabled public String opportunityId { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public String permitNo { get; set; }
        @AuraEnabled public String orderId { get; set; }
        @AuraEnabled public String shippingStreet { get; set; }
        @AuraEnabled public String shippingCity { get; set; }
        @AuraEnabled public String shippingState { get; set; }
        @AuraEnabled public String shippingPostalCode { get; set; }
        @AuraEnabled public String shippingCountry { get; set; }
        @AuraEnabled public String shippingAddress { get; set; }
        @AuraEnabled public Boolean syncToQuickBooks { get; set; }
        @AuraEnabled public String quickbooksPoId { get; set; }
        @AuraEnabled public String integrationStatus { get; set; }
        @AuraEnabled public List<LineItemWrapper> lines { get; set; }
    }

    public class SaveResult {
        @AuraEnabled public String purchaseOrderId { get; set; }
    }

    public class RelatedRecordsWrapper {
        @AuraEnabled public List<Map<String, String>> opportunityOptions = new List<Map<String, String>>();
        @AuraEnabled public List<Map<String, String>> orderOptions = new List<Map<String, String>>();
    }

    public class OrderContextWrapper {
        @AuraEnabled public String orderId { get; set; }
        @AuraEnabled public String orderNumber { get; set; }
        @AuraEnabled public String orderLabel { get; set; }
        @AuraEnabled public String accountId { get; set; }
        @AuraEnabled public String opportunityId { get; set; }
        @AuraEnabled public String shippingStreet { get; set; }
        @AuraEnabled public String shippingCity { get; set; }
        @AuraEnabled public String shippingState { get; set; }
        @AuraEnabled public String shippingPostalCode { get; set; }
        @AuraEnabled public String shippingCountry { get; set; }
        @AuraEnabled public List<LineItemWrapper> lines { get; set; }
    }

    @AuraEnabled(cacheable=true)
    public static OrderContextWrapper getOrderDetails(Id orderId) {
        if (String.isBlank(orderId)) {
            return null;
        }

        String orderSoql = 'SELECT Id, OrderNumber, AccountId, OpportunityId, ' +
            'ShippingStreet, ShippingCity, ShippingState, ShippingPostalCode, ShippingCountry, ' +
            'BillingStreet, BillingCity, BillingState, BillingPostalCode, BillingCountry';
        orderSoql += ' FROM Order WHERE Id = :orderId WITH USER_MODE LIMIT 1';

        Order ord = (Order) Database.query(orderSoql);

        OrderContextWrapper wrapper = new OrderContextWrapper();
        wrapper.orderId = ord.Id;
        wrapper.orderNumber = ord.OrderNumber;
        wrapper.orderLabel = ord.OrderNumber;
        wrapper.accountId = ord.AccountId;
        wrapper.opportunityId = ord.OpportunityId;

        wrapper.shippingStreet = String.isNotBlank(ord.ShippingStreet) ? ord.ShippingStreet : ord.BillingStreet;
        wrapper.shippingCity = String.isNotBlank(ord.ShippingCity) ? ord.ShippingCity : ord.BillingCity;
        wrapper.shippingState = String.isNotBlank(ord.ShippingState) ? ord.ShippingState : ord.BillingState;
        wrapper.shippingPostalCode = String.isNotBlank(ord.ShippingPostalCode) ? ord.ShippingPostalCode : ord.BillingPostalCode;
        wrapper.shippingCountry = String.isNotBlank(ord.ShippingCountry) ? ord.ShippingCountry : ord.BillingCountry;

        wrapper.lines = new List<LineItemWrapper>();

        Map<String, Schema.SObjectField> orderItemFields = Schema.sObjectType.OrderItem.fields.getMap();
        String lineDescField = getActualFieldName(orderItemFields, new List<String>{'Line_Description__c', 'Description'});

        String soql = 'SELECT Id, Product2Id, Product2.Name, Product2.ProductCode, Product2.faxa__QuickBooks_Item_Id__c, Description, Quantity, UnitPrice, TotalPrice';
        if (lineDescField != null && !lineDescField.equalsIgnoreCase('Description')) {
            soql += ', ' + lineDescField;
        }
        soql += ' FROM OrderItem WHERE OrderId = :orderId WITH USER_MODE ORDER BY CreatedDate ASC';

        List<OrderItem> items = Database.query(soql);

        Integer lineIndex = 1;
        for (OrderItem item : items) {
            LineItemWrapper line = new LineItemWrapper();
            line.key = 'line-order-' + (lineIndex++);
            line.productId = item.Product2Id;
            line.productName = item.Product2 != null ? item.Product2.Name : '';
            line.productCode = item.Product2 != null ? item.Product2.ProductCode : '';
            line.quickBooksItemId = item.Product2 != null ? item.Product2.faxa__QuickBooks_Item_Id__c : '';

            String itemDesc = null;
            if (lineDescField != null) {
                itemDesc = (String) item.get(lineDescField);
            }
            if (String.isBlank(itemDesc)) {
                itemDesc = item.Description;
            }
            line.description = itemDesc;

            line.quantity = item.Quantity != null ? item.Quantity : 1;
            line.rate = item.UnitPrice != null ? item.UnitPrice : 0;
            line.amount = item.TotalPrice != null ? item.TotalPrice : (line.quantity * line.rate);
            line.isDeleted = false;
            wrapper.lines.add(line);
        }

        return wrapper;
    }

    @AuraEnabled(cacheable=true)
    public static RelatedRecordsWrapper getRelatedRecordsForAccount(Id accountId) {
        RelatedRecordsWrapper wrapper = new RelatedRecordsWrapper();
        String orderSelect = 'SELECT Id, OrderNumber';
        if (String.isNotBlank(accountId)) {
            for (Opportunity opp : [SELECT Id, Name FROM Opportunity WHERE AccountId = :accountId ORDER BY Name LIMIT 200]) {
                Map<String, String> item = new Map<String, String>();
                item.put('label', opp.Name);
                item.put('value', opp.Id);
                wrapper.opportunityOptions.add(item);
            }
            String orderSoql = orderSelect + ' FROM Order WHERE AccountId = :accountId ORDER BY OrderNumber DESC LIMIT 200';
            for (SObject ordObj : Database.query(orderSoql)) {
                Order ord = (Order) ordObj;
                Map<String, String> item = new Map<String, String>();
                item.put('label', ord.OrderNumber);
                item.put('value', ord.Id);
                wrapper.orderOptions.add(item);
            }
        } else {
            for (Opportunity opp : [SELECT Id, Name FROM Opportunity ORDER BY LastModifiedDate DESC LIMIT 50]) {
                Map<String, String> item = new Map<String, String>();
                item.put('label', opp.Name);
                item.put('value', opp.Id);
                wrapper.opportunityOptions.add(item);
            }
            String orderSoql = orderSelect + ' FROM Order ORDER BY OrderNumber DESC LIMIT 50';
            for (SObject ordObj : Database.query(orderSoql)) {
                Order ord = (Order) ordObj;
                Map<String, String> item = new Map<String, String>();
                item.put('label', ord.OrderNumber);
                item.put('value', ord.Id);
                wrapper.orderOptions.add(item);
            }
        }
        return wrapper;
    }

    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getContactsForAccount(Id accountId) {
        List<Map<String, String>> options = new List<Map<String, String>>();
        if (String.isBlank(accountId)) {
            return options;
        }

        for (Contact contact : [
            SELECT Id, Name
            FROM Contact
            WHERE AccountId = :accountId
            WITH USER_MODE
            ORDER BY Name
            LIMIT 500
        ]) {
            Map<String, String> option = new Map<String, String>();
            option.put('label', contact.Name);
            option.put('value', contact.Id);
            options.add(option);
        }

        return options;
    }

    /**
     * Search standard products using PricebookEntry / Product2
     */
    @AuraEnabled(cacheable=false)
    public static List<ProductOption> searchStandardProducts(String searchTerm) {
        try {
            List<ProductOption> results = new List<ProductOption>();
            String cleanTerm = String.isBlank(searchTerm) ? '' : searchTerm.trim();
            String searchPattern = '%' + cleanTerm + '%';

            Set<Id> matchedPbeIds = new Set<Id>();
            Set<Id> matchedProductIds = new Set<Id>();

            if (String.isBlank(cleanTerm)) {
                List<PricebookEntry> pbes = [
                    SELECT Id, Product2Id, Product2.Name, Product2.ProductCode, Product2.faxa__QuickBooks_Item_Id__c, Product2.Description, UnitPrice
                    FROM PricebookEntry
                    WHERE IsActive = true AND Product2.IsActive = true
                    ORDER BY Product2.Name ASC
                    LIMIT 50
                ];
                for (PricebookEntry pbe : pbes) {
                    matchedPbeIds.add(pbe.Id);
                    matchedProductIds.add(pbe.Product2Id);
                    results.add(mapPbeToOption(pbe));
                }
            } else {
                // Pass 1: Name or ProductCode match on PricebookEntry
                List<PricebookEntry> nameCodePbes = [
                    SELECT Id, Product2Id, Product2.Name, Product2.ProductCode, Product2.faxa__QuickBooks_Item_Id__c, Product2.Description, UnitPrice
                    FROM PricebookEntry
                    WHERE IsActive = true AND Product2.IsActive = true
                    AND (Product2.Name LIKE :searchPattern OR Product2.ProductCode LIKE :searchPattern)
                    ORDER BY Product2.Name ASC
                    LIMIT 50
                ];
                for (PricebookEntry pbe : nameCodePbes) {
                    matchedPbeIds.add(pbe.Id);
                    matchedProductIds.add(pbe.Product2Id);
                    results.add(mapPbeToOption(pbe));
                }

                // Pass 2: Description match on PricebookEntry
                Integer remainingLimit = 50 - results.size();
                if (remainingLimit > 0) {
                    List<PricebookEntry> descPbes = [
                        SELECT Id, Product2Id, Product2.Name, Product2.ProductCode, Product2.faxa__QuickBooks_Item_Id__c, Product2.Description, UnitPrice
                        FROM PricebookEntry
                        WHERE IsActive = true AND Product2.IsActive = true
                        AND Product2.Description LIKE :searchPattern
                        AND Id NOT IN :matchedPbeIds
                        ORDER BY Product2.Name ASC
                        LIMIT :remainingLimit
                    ];
                    for (PricebookEntry pbe : descPbes) {
                        matchedPbeIds.add(pbe.Id);
                        matchedProductIds.add(pbe.Product2Id);
                        results.add(mapPbeToOption(pbe));
                    }
                }

                // Pass 3: Fallback directly on Product2 for active products without PricebookEntry
                remainingLimit = 50 - results.size();
                if (remainingLimit > 0) {
                    List<Product2> directProds = [
                        SELECT Id, Name, ProductCode, faxa__QuickBooks_Item_Id__c, Description
                        FROM Product2
                        WHERE IsActive = true
                        AND (Name LIKE :searchPattern OR ProductCode LIKE :searchPattern OR Description LIKE :searchPattern)
                        AND Id NOT IN :matchedProductIds
                        ORDER BY Name ASC
                        LIMIT :remainingLimit
                    ];
                    for (Product2 prod : directProds) {
                        ProductOption opt = new ProductOption();
                        opt.pricebookEntryId = prod.Id;
                        opt.productId = prod.Id;
                        opt.productName = prod.Name;
                        opt.productCode = prod.ProductCode;
                        opt.quickBooksItemId = prod.faxa__QuickBooks_Item_Id__c;
                        opt.description = prod.Description;
                        opt.unitPrice = 0;
                        opt.cost = 0;
                        opt.taxable = false;
                        results.add(opt);
                    }
                }
            }

            return results;
        } catch (Exception e) {
            throw toAuraHandledException(e);
        }
    }

    private static ProductOption mapPbeToOption(PricebookEntry pbe) {
        ProductOption opt = new ProductOption();
        opt.pricebookEntryId = pbe.Id;
        opt.productId = pbe.Product2Id;
        opt.productName = pbe.Product2 != null ? pbe.Product2.Name : '';
        opt.productCode = pbe.Product2 != null ? pbe.Product2.ProductCode : '';
        opt.quickBooksItemId = pbe.Product2 != null ? pbe.Product2.faxa__QuickBooks_Item_Id__c : '';
        opt.description = pbe.Product2 != null ? pbe.Product2.Description : '';
        opt.unitPrice = pbe.UnitPrice != null ? pbe.UnitPrice : 0;
        opt.cost = 0;
        opt.taxable = false;
        return opt;
    }

    /**
     * Get Picklist values for Purchase Order Status and QuickBooks Sync Status
     */
    @AuraEnabled(cacheable=true)
    public static List<String> getPicklistValues(String fieldApiName) {
        try {
            List<String> values = new List<String>();
            Schema.SObjectType targetType = getPOObjectType();
            if (targetType == null) {
                return values;
            }

            Schema.DescribeSObjectResult objDescribe = targetType.getDescribe();
            Map<String, Schema.SObjectField> fieldMap = objDescribe.fields.getMap();

            List<String> possibleNames = new List<String>{ fieldApiName, fieldApiName.replace('Purchase_Order_', '') };
            String actualField = getActualFieldName(fieldMap, possibleNames);
            if (actualField != null && fieldMap.containsKey(actualField)) {
                Schema.DescribeFieldResult fieldDescribe = fieldMap.get(actualField).getDescribe();
                if (fieldDescribe.isAccessible()) {
                    for (Schema.PicklistEntry entry : fieldDescribe.getPicklistValues()) {
                        if (entry.isActive()) {
                            values.add(entry.getValue());
                        }
                    }
                }
            }
            return values;
        } catch (Exception e) {
            throw toAuraHandledException(e);
        }
    }

    /**
     * Get Class options for line items
     */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getClassOptions() {
        try {
            List<Map<String, String>> options = new List<Map<String, String>>();
            Map<String, Schema.SObjectType> gd = Schema.getGlobalDescribe();
            
            String classObjName = null;
            if (gd.containsKey('faxa__class__c')) {
                classObjName = 'faxa__Class__c';
            } else if (gd.containsKey('class__c')) {
                classObjName = 'Class__c';
            }

            if (classObjName != null) {
                String soql = 'SELECT Id, Name FROM ' + classObjName + ' WITH USER_MODE ORDER BY Name ASC LIMIT 500';
                List<SObject> records = Database.query(soql);
                for (SObject rec : records) {
                    Map<String, String> opt = new Map<String, String>();
                    opt.put('label', (String) rec.get('Name'));
                    opt.put('value', (String) rec.get('Id'));
                    options.add(opt);
                }
            }

            if (options.isEmpty()) {
                Schema.SObjectType lineType = getPOLineObjectType();
                if (lineType != null) {
                    Map<String, Schema.SObjectField> lineFields = lineType.getDescribe().fields.getMap();
                    String classFieldName = getActualFieldName(lineFields, new List<String>{'QuickBooks_Class__c', 'Class__c'});
                    if (classFieldName != null && lineFields.containsKey(classFieldName)) {
                        Schema.DescribeFieldResult dfr = lineFields.get(classFieldName).getDescribe();
                        if (dfr.getType() == Schema.DisplayType.PICKLIST && dfr.isAccessible()) {
                            for (Schema.PicklistEntry entry : dfr.getPicklistValues()) {
                                if (entry.isActive()) {
                                    Map<String, String> opt = new Map<String, String>();
                                    opt.put('label', entry.getLabel());
                                    opt.put('value', entry.getValue());
                                    options.add(opt);
                                }
                            }
                        }
                    }
                }
            }
            return options;
        } catch (Exception e) {
            throw toAuraHandledException(e);
        }
    }

    /**
     * Get Customer Accounts for Line Item lookup.
     * Vendor accounts are excluded from the Customer selector.
     */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getCustomerAccounts(String searchTerm) {
        try {
            List<Map<String, String>> options = new List<Map<String, String>>();
            Map<String, Schema.SObjectField> accFields = Schema.sObjectType.Account.fields.getMap();
            String qbCustIdField = getActualFieldName(accFields, new List<String>{'QuickBooks_Customer_Id__c'});

            String cleanTerm = String.isBlank(searchTerm) ? '' : searchTerm.trim();
            String searchPattern = '%' + cleanTerm + '%';

            List<String> whereClauses = new List<String>();
            if (qbCustIdField != null) {
                whereClauses.add(qbCustIdField + ' != NULL');
            }

            whereClauses.add('(Type = NULL OR Type != \'Vendor\')');

            if (String.isNotBlank(cleanTerm)) {
                whereClauses.add('Name LIKE :searchPattern');
            }

            String soql = 'SELECT Id, Name FROM Account WHERE ' + String.join(whereClauses, ' AND ') + ' ';
            soql += 'WITH USER_MODE ORDER BY Name ASC LIMIT 500';

            List<Account> accounts = Database.query(soql);
            for (Account acc : accounts) {
                Map<String, String> opt = new Map<String, String>();
                opt.put('label', acc.Name);
                opt.put('value', acc.Id);
                options.add(opt);
            }
            return options;
        } catch (Exception e) {
            throw toAuraHandledException(e);
        }
    }

    /**
     * Create Purchase Order with Line Items strictly targetting faxa__Purchase_Order__c or fallbacks
     */
     private static void validateVendor(String vendorId) {
        if (String.isBlank(vendorId)) {
            throw new IllegalArgumentException('Vendor is required.');
        }

        Account vendor = [
            SELECT Id,
                Type,
                faxa__QuickBooks_Vendor_Id__c
            FROM Account
            WHERE Id = :vendorId
            LIMIT 1
        ];

        if (vendor.Type != 'Vendor') {
            throw new IllegalArgumentException('Purchase Orders can only be created for Accounts with Type = Vendor.');
        }

        if (String.isBlank(vendor.faxa__QuickBooks_Vendor_Id__c)) {
            throw new IllegalArgumentException('QuickBooks Vendor Id is missing.');
        }
    }
    @AuraEnabled
    public static SaveResult createPurchaseOrder(PurchaseOrderWrapper request) {
        if (request == null) {
            throw new IllegalArgumentException('Invalid request data.');
        }
        System.debug('request>>>>>'+ request);

        if (String.isBlank(request.poNumber)) {
            throw new IllegalArgumentException('PO Number is required.');
        }
        if (String.isBlank(request.vendorId)) {
            throw new IllegalArgumentException('Vendor is required.');
        }
        if (request.lines == null || request.lines.isEmpty()) {
            throw new IllegalArgumentException('Please add at least one line item before saving the Purchase Order.');
        }
        Boolean hasActiveLines = false;
        for (LineItemWrapper item : request.lines) {
            if (item != null && item.isDeleted != true) {
                hasActiveLines = true;
                break;
            }
        }
        if (!hasActiveLines) {
            throw new IllegalArgumentException('Please add at least one line item before saving the Purchase Order.');
        }
        validateProductQuickBooksItemIds(request.lines);
        validateVendor(request.vendorId);
        Schema.SObjectType poType = getPOObjectType();
        if (poType == null || !poType.getDescribe().isCreateable()) {
            throw new IllegalArgumentException('You do not have permission to create Purchase Orders.');
        }

        Map<String, Schema.SObjectField> poFields = poType.getDescribe().fields.getMap();
        validatePONumberUniqueness(poType, poFields, request.poNumber);

        Savepoint sp = Database.setSavepoint();
        try {
            SObject po = poType.newSObject();

            if (poFields.containsKey('name') && poFields.get('name').getDescribe().isCreateable()) {
                po.put('Name', request.poNumber);
            }
            setFieldVal(po, poFields, new List<String>{'Name', 'PO_No__c', 'PO_Number__c', 'PO_No', 'PO_Number', 'Purchase_Order_Number__c'}, request.poNumber);
            setFieldVal(po, poFields, new List<String>{'Vendor__c', 'Account__c', 'Vendor'}, request.vendorId);
            setFieldVal(po, poFields, new List<String>{'Purchase_Order_Date__c', 'PO_Date__c', 'Date__c'}, String.isNotBlank(request.poDate) ? (Object) request.poDate : (Object) Date.today());
            setFieldVal(po, poFields, new List<String>{'Opportunity__c'}, request.opportunityId);
            setFieldVal(po, poFields, new List<String>{'Purchase_Order_Status__c', 'Status__c'}, request.status);
            setFieldVal(po, poFields, new List<String>{'Permit_No__c', 'Permit_Number__c'}, request.permitNo);
            setFieldVal(po, poFields, new List<String>{'Order__c'}, request.orderId);
            setFieldVal(po, poFields, new List<String>{'Shipping_Street__c'}, request.shippingStreet);
            setFieldVal(po, poFields, new List<String>{'Shipping_City__c'}, request.shippingCity);
            setFieldVal(po, poFields, new List<String>{'Shipping_Postal_Code__c'}, request.shippingPostalCode);
            setFieldVal(po, poFields, new List<String>{'Shipping_State__c'}, request.shippingState);
            setFieldVal(po, poFields, new List<String>{'Shipping_Country__c'}, request.shippingCountry);
            setFieldVal(po, poFields, new List<String>{'Sync_to_QuickBooks__c'}, request.syncToQuickBooks == true);
            setFieldVal(po, poFields, new List<String>{'QuickBooks_Purchase_Order_ID__c', 'QuickBooks_PO_ID__c'}, request.quickbooksPoId);
            setFieldVal(po, poFields, new List<String>{'QuickBooks_Sync_Status__c'}, request.integrationStatus);

            SObjectAccessDecision decision = Security.stripInaccessible(
                AccessType.CREATABLE,
                new List<SObject>{ po }
            );
            insert decision.getRecords();
            SObject insertedPo = decision.getRecords()[0];

            Schema.SObjectType lineType = getPOLineObjectType();
            if (request.lines != null && !request.lines.isEmpty() && lineType != null) {
                if (!lineType.getDescribe().isCreateable()) {
                    throw new IllegalArgumentException('You do not have permission to create Purchase Order Line Items.');
                }

                Map<String, Schema.SObjectField> lineFields = lineType.getDescribe().fields.getMap();
                List<SObject> lineItemsToInsert = new List<SObject>();

                Integer lineNumber = 1;
                for (LineItemWrapper item : request.lines) {
                    if (item.isDeleted == true) {
                        continue;
                    }

                    Decimal qty = item.quantity != null ? item.quantity : 0;
                    Decimal rate = item.rate != null ? item.rate : 0;
                    Decimal lineTotal = qty * rate;

                    SObject line = lineType.newSObject();
                    setFieldVal(line, lineFields, new List<String>{'Purchase_Order__c'}, insertedPo.Id);
                    setFieldVal(line, lineFields, new List<String>{'Product_Service__c', 'Product__c', 'Product'}, item.productId);
                    setFieldVal(line, lineFields, new List<String>{'Quantity__c', 'Qty__c'}, qty);
                    setFieldVal(line, lineFields, new List<String>{'Unit_Price__c', 'Rate__c', 'UnitPrice__c', 'Price__c'}, rate);
                    setFieldVal(line, lineFields, new List<String>{'QuickBooks_Class__c', 'Class__c', 'Class'}, item.classId);
                    setFieldVal(line, lineFields, new List<String>{'Customer__c', 'Quickbooks_Customer__c', 'Account__c'}, item.customerId);
                    setFieldVal(line, lineFields, new List<String>{'Amount__c', 'Total__c'}, lineTotal);
                    setFieldVal(line, lineFields, new List<String>{'Description__c'}, item.description);
                    setFieldVal(line, lineFields, new List<String>{'Line_Number__c'}, lineNumber++);
                    lineItemsToInsert.add(line);
                }

                if (!lineItemsToInsert.isEmpty()) {
                    SObjectAccessDecision lineDecision = Security.stripInaccessible(
                        AccessType.CREATABLE,
                        lineItemsToInsert
                    );
                    insert lineDecision.getRecords();
                }
            }

            SaveResult result = new SaveResult();
            result.purchaseOrderId = insertedPo.Id;
            return result;

        } catch (Exception e) {
            Database.rollback(sp);
            throw toAuraHandledException(e);
        }
    }

    private static void validateProductQuickBooksItemIds(List<LineItemWrapper> lines) {
        Set<Id> productIds = new Set<Id>();
        Map<Id, String> productNamesById = new Map<Id, String>();
        for (LineItemWrapper line : lines) {
            if (line == null || line.isDeleted == true || String.isBlank(line.productId)) {
                continue;
            }
            Id productId = (Id) line.productId;
            productIds.add(productId);
            productNamesById.put(productId, String.isNotBlank(line.productName) ? line.productName : line.productId);
        }

        if (productIds.isEmpty()) {
            return;
        }

        Set<String> missingProductNames = new Set<String>();
        for (Product2 product : [
            SELECT Id, Name, faxa__QuickBooks_Item_Id__c
            FROM Product2
            WHERE Id IN :productIds
            WITH USER_MODE
        ]) {
            if (String.isBlank(product.faxa__QuickBooks_Item_Id__c)) {
                missingProductNames.add(String.isNotBlank(product.Name) ? product.Name : productNamesById.get(product.Id));
            }
        }

        if (missingProductNames.isEmpty()) {
            return;
        }

        List<String> quotedProductNames = new List<String>();
        for (String productName : missingProductNames) {
            quotedProductNames.add('"' + productName + '"');
        }

        String productLabel = quotedProductNames.size() == 1 ? 'product ' : 'products ';
        String verb = quotedProductNames.size() == 1 ? ' is ' : ' are ';
        String instruction = quotedProductNames.size() == 1 ? 'the product' : 'the products';
        throw new IllegalArgumentException(
            'Cannot save Purchase Order. The ' + productLabel + String.join(quotedProductNames, ', ') +
            verb + 'missing a QuickBooks Item ID (faxa__QuickBooks_Item_Id__c). Please update ' +
            instruction + ' and try again.'
        );
    }

    private static Schema.SObjectType getPOObjectType() {
        Map<String, Schema.SObjectType> gd = Schema.getGlobalDescribe();
        if (gd.containsKey('faxa__purchase_order__c')) {
            return gd.get('faxa__purchase_order__c');
        }
        if (gd.containsKey('purchase_order__c')) {
            return gd.get('purchase_order__c');
        }
        return null;
    }

    private static Schema.SObjectType getPOLineObjectType() {
        Map<String, Schema.SObjectType> gd = Schema.getGlobalDescribe();
        if (gd.containsKey('faxa__purchase_order_line__c')) {
            return gd.get('faxa__purchase_order_line__c');
        }
        if (gd.containsKey('purchase_order_line__c')) {
            return gd.get('purchase_order_line__c');
        }
        if (gd.containsKey('faxa__purchase_order_line_item__c')) {
            return gd.get('faxa__purchase_order_line_item__c');
        }
        if (gd.containsKey('purchase_order_line_item__c')) {
            return gd.get('purchase_order_line_item__c');
        }
        return null;
    }

    private static String getActualFieldName(Map<String, Schema.SObjectField> fieldMap, List<String> candidates) {
        if (fieldMap == null || candidates == null) return null;
        Map<String, String> lowerToActual = new Map<String, String>();
        for (String fName : fieldMap.keySet()) {
            lowerToActual.put(fName.toLowerCase(), fName);
        }
        for (String c : candidates) {
            String candidateLower = c.toLowerCase();
            String faxaLower = ('faxa__' + c).toLowerCase();
            if (lowerToActual.containsKey(faxaLower)) {
                return lowerToActual.get(faxaLower);
            }
            if (lowerToActual.containsKey(candidateLower)) {
                return lowerToActual.get(candidateLower);
            }
        }
        return null;
    }

    private static void setFieldVal(SObject sObj, Map<String, Schema.SObjectField> fieldMap, List<String> candidates, Object val) {
        if (val == null) return;
        String actualName = getActualFieldName(fieldMap, candidates);
        if (actualName != null) {
            Schema.DescribeFieldResult dfr = fieldMap.get(actualName).getDescribe();
            if (dfr.isCreateable()) {
                Schema.DisplayType dt = dfr.getType();
                if (dt == Schema.DisplayType.DATE && val instanceof String) {
                    if (String.isNotBlank((String) val)) {
                        sObj.put(actualName, Date.valueOf((String) val));
                    }
                } else if (dt == Schema.DisplayType.DATETIME && val instanceof String) {
                    if (String.isNotBlank((String) val)) {
                        sObj.put(actualName, Datetime.valueOf((String) val));
                    }
                } else if (dt == Schema.DisplayType.ID && val instanceof String) {
                    if (String.isNotBlank((String) val)) {
                        sObj.put(actualName, (Id) val);
                    }
                } else if (dt == Schema.DisplayType.BOOLEAN && val instanceof String) {
                    sObj.put(actualName, Boolean.valueOf((String) val));
                } else {
                    sObj.put(actualName, val);
                }
            }
        }
    }

    private static void validatePONumberUniqueness(Schema.SObjectType poType, Map<String, Schema.SObjectField> poFields, String poNumber) {
        if (poType == null || String.isBlank(poNumber) || poFields == null) {
            return;
        }

        String poObjName = poType.getDescribe().getName();
        List<String> poNumCandidates = new List<String>{'Name', 'PO_No__c', 'PO_Number__c', 'PO_No', 'PO_Number', 'Purchase_Order_Number__c'};

        Set<String> fieldsToCheck = new Set<String>();
        for (String candidate : poNumCandidates) {
            String actualField = getActualFieldName(poFields, new List<String>{candidate});
            if (actualField != null && poFields.containsKey(actualField)) {
                fieldsToCheck.add(actualField);
            }
        }

        if (fieldsToCheck.isEmpty()) {
            return;
        }

        List<String> whereClauses = new List<String>();
        for (String fieldName : fieldsToCheck) {
            whereClauses.add(fieldName + ' = :poNumber');
        }

        String queryStr = 'SELECT Id FROM ' + poObjName + ' WHERE ' + String.join(whereClauses, ' OR ') + ' LIMIT 1';
        List<SObject> existingPOs = Database.query(queryStr);

        if (!existingPOs.isEmpty()) {
            throw new IllegalArgumentException('A Purchase Order with PO Number "' + poNumber + '" already exists. Please enter a unique PO Number.');
        }
    }

    private static Exception toAuraHandledException(Exception e) {
        System.debug(LoggingLevel.ERROR, 'NewPurchaseOrderController Error: ' + e.getMessage() + '\n' + e.getStackTraceString());
        if (e instanceof AuraHandledException) {
            return e;
        }
        AuraHandledException ahe = new AuraHandledException(e.getMessage());
        ahe.setMessage(e.getMessage());
        return ahe;
    }
}