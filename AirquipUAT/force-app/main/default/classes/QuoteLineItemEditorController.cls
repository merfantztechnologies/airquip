public with sharing class QuoteLineItemEditorController {
    private static final Integer PRODUCT_SEARCH_LIMIT = 50;
    private static final String PRODUCT_PURCHASE_COST_FIELD = 'faxa__Purchase_Cost__c';

    public class ProductOption {
        @AuraEnabled public Id pricebookEntryId { get; set; }
        @AuraEnabled public Id productId { get; set; }
        @AuraEnabled public String productName { get; set; }
        @AuraEnabled public String productCode { get; set; }
        @AuraEnabled public String productDescription { get; set; }
        @AuraEnabled public Decimal cost { get; set; }
        @AuraEnabled public Decimal salesPrice { get; set; }
    }

    public class LineItemRow {
        @AuraEnabled public Id quoteLineItemId { get; set; }
        @AuraEnabled public Id pricebookEntryId { get; set; }
        @AuraEnabled public Id productId { get; set; }
        @AuraEnabled public String productName { get; set; }
        @AuraEnabled public String productCode { get; set; }
        @AuraEnabled public Decimal cost { get; set; }
        @AuraEnabled public Decimal salesPrice { get; set; }
        @AuraEnabled public Decimal quantity { get; set; }
        @AuraEnabled public Decimal subtotal { get; set; }
        @AuraEnabled public Decimal totalPrice { get; set; }
        @AuraEnabled public Boolean includeInQuote { get; set; }
        @AuraEnabled public String lineItemDescription { get; set; }
        @AuraEnabled public Map<String, String> quoteLineFieldValues { get; set; }
    }

    public class QuoteLineItemFieldOption {
        @AuraEnabled public String apiName { get; set; }
        @AuraEnabled public String label { get; set; }
        @AuraEnabled public String dataType { get; set; }
    }

    private static final Set<String> DEFAULT_QUOTE_LINE_TABLE_FIELD_API_NAMES = new Set<String>{
        'Cost__c',
        'UnitPrice',
        'Quantity',
        'Quantity__c',
        'Subtotal',
        'TotalPrice',
        'Costs__c',
        'Total_Price__c',
        'Include_In_Quote__c',
        'Line_Item_Description__c',
        'Description',
        'ListPrice',
        'Discount'
    };

    private static final Set<String> RESERVED_QUOTE_LINE_FIELD_API_NAMES = new Set<String>{
        'Id',
        'QuoteId',
        'PricebookEntryId',
        'Product2Id',
        'LineNumber',
        'SortOrder',
        'IsDeleted',
        'CreatedDate',
        'CreatedById',
        'LastModifiedDate',
        'LastModifiedById',
        'SystemModstamp',
        'LastReferencedDate',
        'LastViewedDate',
        'LastActivityDate'
    };

    private static final Set<Schema.DisplayType> SELECTABLE_QUOTE_LINE_FIELD_TYPES = new Set<Schema.DisplayType>{
        Schema.DisplayType.STRING,
        Schema.DisplayType.TEXTAREA,
        Schema.DisplayType.PICKLIST,
        Schema.DisplayType.MULTIPICKLIST,
        Schema.DisplayType.BOOLEAN,
        Schema.DisplayType.DATE,
        Schema.DisplayType.DATETIME,
        Schema.DisplayType.CURRENCY,
        Schema.DisplayType.DOUBLE,
        Schema.DisplayType.INTEGER,
        Schema.DisplayType.PERCENT,
        Schema.DisplayType.EMAIL,
        Schema.DisplayType.PHONE,
        Schema.DisplayType.URL
    };

    public class SaveRequest {
        @AuraEnabled
        public Id quoteId { get; set; }
    
        @AuraEnabled
        public List<LineItemRow> rows { get; set; }
    
        @AuraEnabled
        public List<Id> deletedLineItemIds { get; set; }
    }

    @AuraEnabled(cacheable=true)
    public static List<QuoteLineItemFieldOption> getQuoteLineItemFieldOptions() {
        try {
            Map<String, Schema.SObjectField> fieldMap = Schema.SObjectType.QuoteLineItem.fields.getMap();
            List<QuoteLineItemFieldOption> options = new List<QuoteLineItemFieldOption>();
            List<String> apiNames = new List<String>(fieldMap.keySet());
            apiNames.sort();

            for (String fieldKey : apiNames) {
                Schema.DescribeFieldResult describe = fieldMap.get(fieldKey).getDescribe();
                String apiName = describe.getName();
                if (isReservedQuoteLineField(apiName) || isDefaultQuoteLineTableField(apiName)) {
                    continue;
                }
                if (!describe.isAccessible() || !SELECTABLE_QUOTE_LINE_FIELD_TYPES.contains(describe.getType())) {
                    continue;
                }
                QuoteLineItemFieldOption option = new QuoteLineItemFieldOption();
                option.apiName = apiName;
                option.label = describe.getLabel();
                option.dataType = String.valueOf(describe.getType());
                options.add(option);
            }
            return options;
        } catch (Exception e) {
            throw new AuraHandledException('Unable to load Quote Line Item fields. Please try again.');
        }
    }

    @AuraEnabled
    public static List<LineItemRow> getQuoteLineItems(Id quoteId, List<String> additionalFieldApiNames) {
        try {
            if (quoteId == null) {
                throw new AuraHandledException('Quote Id is required.');
            }

            List<String> validatedFields = validateAdditionalQuoteLineFields(additionalFieldApiNames);
            Map<String, Schema.DisplayType> fieldTypesByApiName = getValidatedQuoteLineFieldTypes(validatedFields);
            String additionalSelectClause = buildQuoteLineSelectClause(validatedFields);

            String soql =
                'SELECT Id, PricebookEntryId, Product2Id, Product2.Name, Product2.ProductCode' +
                productPurchaseCostSelectClause() +
                ', SortOrder, Cost__c, UnitPrice, Quantity, Subtotal, TotalPrice, ' +
                'Include_In_Quote__c, Line_Item_Description__c' +
                additionalSelectClause +
                ' FROM QuoteLineItem' +
                ' WHERE QuoteId = :quoteId' +
                ' ORDER BY SortOrder ASC NULLS LAST, CreatedDate ASC';

            List<LineItemRow> rows = new List<LineItemRow>();
            for (QuoteLineItem item : Database.query(soql)) {
                LineItemRow row = new LineItemRow();
                row.quoteLineItemId = item.Id;
                row.pricebookEntryId = item.PricebookEntryId;
                row.productId = item.Product2Id;
                row.productName = item.Product2 != null ? item.Product2.Name : null;
                row.productCode = item.Product2 != null ? item.Product2.ProductCode : null;
                row.cost = item.Cost__c != null ? item.Cost__c : resolveProductPurchaseCost(item.Product2);
                row.salesPrice = item.UnitPrice;
                row.quantity = item.Quantity;
                row.subtotal = item.Subtotal;
                row.totalPrice = item.TotalPrice;
                row.includeInQuote = item.Include_In_Quote__c;
                row.lineItemDescription = item.Line_Item_Description__c;
                row.quoteLineFieldValues = new Map<String, String>();
                for (String fieldApiName : validatedFields) {
                    Schema.DisplayType fieldType = fieldTypesByApiName.get(fieldApiName);
                    Object rawValue = item.get(fieldApiName);
                    if (rawValue == null) {
                        rawValue = item.getPopulatedFieldsAsMap().get(fieldApiName);
                    }
                    row.quoteLineFieldValues.put(
                        fieldApiName,
                        formatQuoteLineFieldValue(rawValue, fieldType)
                    );
                }
                rows.add(row);
            }
            return rows;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('Unable to load Quote Line Items. Please refresh and try again.');
        }
    }

    @AuraEnabled(cacheable=false)
    public static List<ProductOption> searchActiveProducts(Id quoteId, String searchTerm) {
        try {
            if (quoteId == null) {
                throw new AuraHandledException('Quote Id is required.');
            }

            Id pricebookId = resolvePricebookId(quoteId);
            String selectFields = buildProductSearchSelectFields();
            List<ProductOption> output = new List<ProductOption>();

            if (String.isBlank(searchTerm)) {
                String soql =
                    'SELECT ' +
                    selectFields +
                    ' FROM PricebookEntry WHERE Pricebook2Id = :pricebookId AND IsActive = TRUE AND Product2.IsActive = TRUE' +
                    ' ORDER BY Product2.Name LIMIT ' +
                    PRODUCT_SEARCH_LIMIT;
                for (PricebookEntry pbe : Database.query(soql)) {
                    output.add(mapPricebookEntryToProductOption(pbe));
                }
                return output;
            }

            String likeStr = '%' + searchTerm.trim() + '%';
            Set<Id> matchedEntryIds = new Set<Id>();

            String nameCodeSoql =
                'SELECT ' +
                selectFields +
                ' FROM PricebookEntry WHERE Pricebook2Id = :pricebookId AND IsActive = TRUE AND Product2.IsActive = TRUE' +
                ' AND (Product2.Name LIKE :likeStr OR Product2.ProductCode LIKE :likeStr)' +
                ' ORDER BY Product2.Name LIMIT ' +
                PRODUCT_SEARCH_LIMIT;
            for (PricebookEntry pbe : Database.query(nameCodeSoql)) {
                matchedEntryIds.add(pbe.Id);
                output.add(mapPricebookEntryToProductOption(pbe));
            }

            Integer remainingLimit = PRODUCT_SEARCH_LIMIT - output.size();
            if (remainingLimit > 0) {
                String descriptionSoql =
                    'SELECT ' +
                    selectFields +
                    ' FROM PricebookEntry WHERE Pricebook2Id = :pricebookId AND IsActive = TRUE AND Product2.IsActive = TRUE' +
                    ' AND Product2.Description LIKE :likeStr AND Id NOT IN :matchedEntryIds' +
                    ' ORDER BY Product2.Name LIMIT ' +
                    remainingLimit;
                for (PricebookEntry pbe : Database.query(descriptionSoql)) {
                    output.add(mapPricebookEntryToProductOption(pbe));
                }
            }

            return output;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('Unable to search products right now. Please try again.');
        }
    }

    @AuraEnabled
    public static void saveQuoteLineItems(SaveRequest request) {
        try {
            validateSaveRequest(request);
            
            Quote quoteRecord = [
                SELECT Id, Pricebook2Id
                FROM Quote
                WHERE Id = :request.quoteId
                LIMIT 1
            ];
            Id pricebookId = quoteRecord.Pricebook2Id;
            if (pricebookId == null) {
                pricebookId = resolvePricebookId(request.quoteId);
                quoteRecord.Pricebook2Id = pricebookId;
                update quoteRecord;
            }

            List<LineItemRow> rows = request.rows == null ? new List<LineItemRow>() : request.rows;
            List<Id> deletedIds = request.deletedLineItemIds == null ? new List<Id>() : request.deletedLineItemIds;

            Set<Id> submittedPbeIds = new Set<Id>();
            for (LineItemRow row : rows) {
                if (row != null && row.pricebookEntryId != null) {
                    submittedPbeIds.add(row.pricebookEntryId);
                }
            }

            Map<Id, PricebookEntry> pbeById = new Map<Id, PricebookEntry>();
            if (!submittedPbeIds.isEmpty()) {
                for (PricebookEntry pbe : [
                    SELECT Id, Pricebook2Id, UnitPrice, Product2Id, Product2.faxa__Purchase_Cost__c
                    FROM PricebookEntry
                    WHERE Id IN :submittedPbeIds
                ]) {
                    pbeById.put(pbe.Id, pbe);
                }
            }

            List<QuoteLineItem> toUpsert = new List<QuoteLineItem>();
            for (Integer index = 0; index < rows.size(); index++) {
                LineItemRow row = rows[index];
                validateRow(row, index, pbeById, pricebookId);
                PricebookEntry selectedPbe = pbeById.get(row.pricebookEntryId);

                QuoteLineItem qli = new QuoteLineItem();
                if (row.quoteLineItemId != null) {
                    qli.Id = row.quoteLineItemId;
                }
                
                
                qli.Quantity = row.quantity;
                qli.UnitPrice = row.salesPrice;
                qli.Cost__c = row.cost != null
                    ? row.cost
                    : resolveProductPurchaseCost(selectedPbe.Product2);
                qli.Include_In_Quote__c = row.includeInQuote == null ? true : row.includeInQuote;
                qli.Line_Item_Description__c = row.lineItemDescription;
                qli.SortOrder = index + 1;
                if (row.quoteLineItemId == null) {
                    qli.QuoteId = request.quoteId;
                    qli.PricebookEntryId = row.pricebookEntryId;
                }
                toUpsert.add(qli);
            }

            if (!toUpsert.isEmpty()) {
                upsert toUpsert;

                List<QuoteLineItem> sortOrderUpdates = new List<QuoteLineItem>();
                for (QuoteLineItem qli : toUpsert) {
                    if (qli.Id != null && qli.SortOrder != null) {
                        sortOrderUpdates.add(
                            new QuoteLineItem(Id = qli.Id, SortOrder = qli.SortOrder)
                        );
                    }
                }
                if (!sortOrderUpdates.isEmpty()) {
                    update sortOrderUpdates;
                }
            }

            if (!deletedIds.isEmpty()) {
                List<QuoteLineItem> toDelete = [
                    SELECT Id
                    FROM QuoteLineItem
                    WHERE Id IN :deletedIds
                      AND QuoteId = :request.quoteId
                ];
                if (!toDelete.isEmpty()) {
                    delete toDelete;
                }
            }

            Integer remainingLineItemCount = [
                SELECT COUNT()
                FROM QuoteLineItem
                WHERE QuoteId = :request.quoteId
            ];
            if (remainingLineItemCount == 0) {
                List<Quote> quotesToUpdate = new List<Quote>{
                    new Quote(Id = request.quoteId, Tax = 0)
                };
                update quotesToUpdate;
            }
        } catch (AuraHandledException e) {
            throw e;
        } catch (DmlException e) {
            throw new AuraHandledException(buildDmlMessage(e));
        } catch (Exception e) {
            throw new AuraHandledException('Unable to save quote lines. Please verify values and try again.');
        }
    }

    private static void validateSaveRequest(SaveRequest request) {
        if (request == null) {
            throw new AuraHandledException('Save request is required.');
        }
        if (request.quoteId == null) {
            throw new AuraHandledException('Quote Id is required.');
        }
    }

    private static void validateRow(
        LineItemRow row,
        Integer rowIndex,
        Map<Id, PricebookEntry> pbeById,
        Id expectedPricebookId
    ) {
        Integer displayRow = rowIndex + 1;
        if (row == null) {
            throw new AuraHandledException('Row ' + displayRow + ' is invalid.');
        }
        if (row.pricebookEntryId == null) {
            throw new AuraHandledException('Row ' + displayRow + ': Product is required.');
        }
        PricebookEntry pbe = pbeById.get(row.pricebookEntryId);
        if (pbe == null || pbe.Pricebook2Id != expectedPricebookId) {
            throw new AuraHandledException('Row ' + displayRow + ': Selected product is not valid for this Quote.');
        }
        if (row.quantity == null || row.quantity <= 0) {
            throw new AuraHandledException('Row ' + displayRow + ': Quantity must be greater than zero.');
        }
        if (row.salesPrice == null || row.salesPrice < 0) {
            throw new AuraHandledException('Row ' + displayRow + ': Sales Price cannot be negative.');
        }
    }

    private static List<String> validateAdditionalQuoteLineFields(List<String> requestedFieldApiNames) {
        List<String> validated = new List<String>();
        if (requestedFieldApiNames == null || requestedFieldApiNames.isEmpty()) {
            return validated;
        }

        Map<String, Schema.SObjectField> fieldMap = Schema.SObjectType.QuoteLineItem.fields.getMap();
        Set<String> seenLower = new Set<String>();
        for (String requestedApiName : requestedFieldApiNames) {
            if (String.isBlank(requestedApiName)) {
                continue;
            }
            String canonicalApiName = resolveQuoteLineFieldApiName(requestedApiName, fieldMap);
            if (canonicalApiName == null) {
                continue;
            }
            String seenKey = canonicalApiName.toLowerCase();
            if (seenLower.contains(seenKey)) {
                continue;
            }
            if (isReservedQuoteLineField(canonicalApiName) || isDefaultQuoteLineTableField(canonicalApiName)) {
                continue;
            }
            Schema.SObjectField fieldToken = fieldMap.get(resolveQuoteLineFieldMapKey(canonicalApiName, fieldMap));
            Schema.DescribeFieldResult describe = fieldToken.getDescribe();
            if (!describe.isAccessible() || !SELECTABLE_QUOTE_LINE_FIELD_TYPES.contains(describe.getType())) {
                continue;
            }
            seenLower.add(seenKey);
            validated.add(canonicalApiName);
        }
        return validated;
    }

    private static Map<String, Schema.DisplayType> getValidatedQuoteLineFieldTypes(List<String> validatedFields) {
        Map<String, Schema.DisplayType> fieldTypesByApiName = new Map<String, Schema.DisplayType>();
        Map<String, Schema.SObjectField> fieldMap = Schema.SObjectType.QuoteLineItem.fields.getMap();
        for (String fieldApiName : validatedFields) {
            String fieldKey = resolveQuoteLineFieldMapKey(fieldApiName, fieldMap);
            fieldTypesByApiName.put(fieldApiName, fieldMap.get(fieldKey).getDescribe().getType());
        }
        return fieldTypesByApiName;
    }

    private static String resolveQuoteLineFieldApiName(
        String requestedApiName,
        Map<String, Schema.SObjectField> fieldMap
    ) {
        if (String.isBlank(requestedApiName)) {
            return null;
        }
        String fieldKey = resolveQuoteLineFieldMapKey(requestedApiName, fieldMap);
        return fieldKey == null ? null : fieldMap.get(fieldKey).getDescribe().getName();
    }

    private static String resolveQuoteLineFieldMapKey(
        String requestedApiName,
        Map<String, Schema.SObjectField> fieldMap
    ) {
        if (String.isBlank(requestedApiName) || fieldMap == null) {
            return null;
        }
        if (fieldMap.containsKey(requestedApiName)) {
            return requestedApiName;
        }
        for (String fieldKey : fieldMap.keySet()) {
            if (fieldKey.equalsIgnoreCase(requestedApiName)) {
                return fieldKey;
            }
        }
        return null;
    }

    private static Boolean isDefaultQuoteLineTableField(String apiName) {
        if (String.isBlank(apiName)) {
            return false;
        }
        for (String defaultApiName : DEFAULT_QUOTE_LINE_TABLE_FIELD_API_NAMES) {
            if (defaultApiName.equalsIgnoreCase(apiName)) {
                return true;
            }
        }
        return false;
    }

    private static Boolean isReservedQuoteLineField(String apiName) {
        if (String.isBlank(apiName)) {
            return false;
        }
        for (String reservedApiName : RESERVED_QUOTE_LINE_FIELD_API_NAMES) {
            if (reservedApiName.equalsIgnoreCase(apiName)) {
                return true;
            }
        }
        return false;
    }

    private static String buildQuoteLineSelectClause(List<String> validatedFields) {
        if (validatedFields.isEmpty()) {
            return '';
        }
        List<String> selectParts = new List<String>();
        for (String fieldApiName : validatedFields) {
            selectParts.add(fieldApiName);
        }
        return ', ' + String.join(selectParts, ', ');
    }

    private static String formatQuoteLineFieldValue(Object rawValue, Schema.DisplayType fieldType) {
        if (rawValue == null) {
            return '';
        }
        if (fieldType == Schema.DisplayType.BOOLEAN) {
            return (Boolean) rawValue ? 'Yes' : 'No';
        }
        if (fieldType == Schema.DisplayType.DATE) {
            return String.valueOf((Date) rawValue);
        }
        if (fieldType == Schema.DisplayType.DATETIME) {
            Datetime dt = (Datetime) rawValue;
            return dt.format('MM/dd/yyyy h:mm a');
        }
        if (
            fieldType == Schema.DisplayType.CURRENCY ||
            fieldType == Schema.DisplayType.DOUBLE ||
            fieldType == Schema.DisplayType.PERCENT ||
            fieldType == Schema.DisplayType.INTEGER
        ) {
            return String.valueOf(rawValue);
        }
        return String.valueOf(rawValue);
    }

    private static Boolean fieldExists(Schema.SObjectType typ, String fieldApi) {
        return typ.getDescribe().fields.getMap().containsKey(fieldApi.toLowerCase());
    }

    private static Boolean productHasPurchaseCostField() {
        return fieldExists(Product2.SObjectType, PRODUCT_PURCHASE_COST_FIELD);
    }

    private static String productPurchaseCostSelectClause() {
        return productHasPurchaseCostField() ? ', Product2.' + PRODUCT_PURCHASE_COST_FIELD : '';
    }

    private static Decimal resolveProductPurchaseCost(SObject productRecord) {
        if (productRecord == null || !productHasPurchaseCostField()) {
            return null;
        }
        return (Decimal) productRecord.get(PRODUCT_PURCHASE_COST_FIELD);
    }

    private static String buildProductSearchSelectFields() {
        return 'Id, UnitPrice, Product2Id, Product2.Name, Product2.ProductCode, Product2.Description' +
            productPurchaseCostSelectClause();
    }

    private static ProductOption mapPricebookEntryToProductOption(PricebookEntry pbe) {
        ProductOption option = new ProductOption();
        option.pricebookEntryId = pbe.Id;
        option.productId = pbe.Product2Id;
        option.productName = pbe.Product2 != null ? pbe.Product2.Name : null;
        option.productCode = pbe.Product2 != null ? pbe.Product2.ProductCode : null;
        option.productDescription = pbe.Product2 != null ? pbe.Product2.Description : null;
        option.salesPrice = pbe.UnitPrice;
        option.cost = resolveProductPurchaseCost(pbe.Product2);
        return option;
    }

    private static Id resolvePricebookId(Id quoteId) {
        Quote quoteRecord = [
            SELECT Id, Pricebook2Id
            FROM Quote
            WHERE Id = :quoteId
            LIMIT 1
        ];
        if (quoteRecord.Pricebook2Id != null) {
            return quoteRecord.Pricebook2Id;
        }
        for (Pricebook2 pb : [
            SELECT Id
            FROM Pricebook2
            WHERE IsStandard = TRUE
              AND IsActive = TRUE
            LIMIT 1
        ]) {
            return pb.Id;
        }
        throw new AuraHandledException(
            'No active Price Book is associated with this Quote. Set a Price Book on the Quote or activate the Standard Price Book.'
        );
    }

    private static String buildDmlMessage(DmlException e) {
        if (e == null) {
            return 'Unable to save quote lines due to a data error.';
        }
        Set<String> uniqueMessages = new Set<String>();
        List<String> messages = new List<String>();
        for (Integer i = 0; i < e.getNumDml(); i++) {
            String msg = e.getDmlMessage(i);
            if (!String.isBlank(msg) && !uniqueMessages.contains(msg)) {
                uniqueMessages.add(msg);
                messages.add(msg);
            }
        }
        if (!messages.isEmpty()) {
            return String.join(messages, ' ');
        }
        return 'Unable to save quote lines due to a data error.';
    }
}