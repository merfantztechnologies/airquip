public with sharing class InvoiceLineItemEditorController {
    private static final Integer PRODUCT_SEARCH_LIMIT = 50;
    private static final String INVOICE_PRICEBOOK_FIELD = 'fax__Pricebook__c';
    private static final String PRODUCT_PURCHASE_COST_FIELD = 'faxa__Purchase_Cost__c';

    public class ProductOption {
        @AuraEnabled public Id pricebookEntryId { get; set; }
        @AuraEnabled public Id productId { get; set; }
        @AuraEnabled public String productName { get; set; }
        @AuraEnabled public String productCode { get; set; }
        @AuraEnabled public String productDescription { get; set; }
        @AuraEnabled public Decimal cost { get; set; }
        @AuraEnabled public Decimal salesPrice { get; set; }
        @AuraEnabled public Boolean taxable { get; set; }
    }

    public class InvoiceSummaryContext {
        @AuraEnabled public Decimal taxPercent { get; set; }
        @AuraEnabled public Decimal subTotalTaxProduct { get; set; }
    }

    public class LineItemRow {
        @AuraEnabled public Id invoiceLineItemId { get; set; }
        @AuraEnabled public String lineItemName { get; set; }
        @AuraEnabled public Id pricebookEntryId { get; set; }
        @AuraEnabled public Id productId { get; set; }
        @AuraEnabled public String productName { get; set; }
        @AuraEnabled public String productCode { get; set; }
        @AuraEnabled public Decimal cost { get; set; }
        @AuraEnabled public Decimal salesPrice { get; set; }
        @AuraEnabled public Decimal quantity { get; set; }
        @AuraEnabled public Decimal discount { get; set; }
        @AuraEnabled public Decimal discountAmt { get; set; }
        @AuraEnabled public Decimal subtotal { get; set; }
        @AuraEnabled public Decimal totalPrice { get; set; }
        @AuraEnabled public Decimal amountExclTax { get; set; }
        @AuraEnabled public Decimal taxPercent { get; set; }
        @AuraEnabled public Decimal taxAmount { get; set; }
        @AuraEnabled public Boolean includeInInvoice { get; set; }
        @AuraEnabled public Boolean taxable { get; set; }
        @AuraEnabled public String lineItemDescription { get; set; }
        @AuraEnabled public Map<String, String> invoiceLineFieldValues { get; set; }
        @AuraEnabled public Decimal sortOrder { get; set; }
    }

    public class InvoiceLineItemFieldOption {
        @AuraEnabled public String apiName { get; set; }
        @AuraEnabled public String label { get; set; }
        @AuraEnabled public String dataType { get; set; }
    }

    private static final Set<String> DEFAULT_INVOICE_LINE_TABLE_FIELD_API_NAMES = new Set<String>{
        'Cost__c',
        'fax__Cost__c',
        'fax__Unit_Price__c',
        'fax__Qty__c',
        'Quantity__c',
        'fax__Discount__c',
        'fax__Total_Amount__c',
        'fax__Total_Amount_Excl_Tax__c',
        'fax__Tax__c',
        'Include_In_Invoice__c',
        'Description__c',
        'Taxable__c',
        'fax__Product__c',
        'fax__Invoice__c'
    };

    private static final Set<String> RESERVED_INVOICE_LINE_FIELD_API_NAMES = new Set<String>{
        'Id',
        'Name',
        'OwnerId',
        'IsDeleted',
        'CreatedDate',
        'CreatedById',
        'LastModifiedDate',
        'LastModifiedById',
        'SystemModstamp',
        'LastReferencedDate',
        'LastViewedDate',
        'LastActivityDate',
        'Sort_Order__c'
    };

    private static final Set<Schema.DisplayType> SELECTABLE_INVOICE_LINE_FIELD_TYPES = new Set<Schema.DisplayType>{
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
        @AuraEnabled public Id invoiceId { get; set; }
        @AuraEnabled public List<LineItemRow> rows { get; set; }
        @AuraEnabled public List<Id> deletedLineItemIds { get; set; }
    }

    @AuraEnabled(cacheable=true)
    public static List<InvoiceLineItemFieldOption> getInvoiceLineItemFieldOptions() {
        try {
            Map<String, Schema.SObjectField> fieldMap = Schema.SObjectType.fax__Invoice_Line_Item__c.fields.getMap();
            List<InvoiceLineItemFieldOption> options = new List<InvoiceLineItemFieldOption>();
            List<String> apiNames = new List<String>(fieldMap.keySet());
            apiNames.sort();

            for (String fieldKey : apiNames) {
                Schema.DescribeFieldResult describe = fieldMap.get(fieldKey).getDescribe();
                String apiName = describe.getName();
                if (isReservedInvoiceLineField(apiName) || isDefaultInvoiceLineTableField(apiName)) {
                    continue;
                }
                if (!describe.isAccessible() || !SELECTABLE_INVOICE_LINE_FIELD_TYPES.contains(describe.getType())) {
                    continue;
                }
                InvoiceLineItemFieldOption option = new InvoiceLineItemFieldOption();
                option.apiName = apiName;
                option.label = describe.getLabel();
                option.dataType = String.valueOf(describe.getType());
                options.add(option);
            }
            return options;
        } catch (Exception e) {
            throw new AuraHandledException('Unable to load Invoice Line Item fields. Please try again.');
        }
    }

    @AuraEnabled
    public static List<LineItemRow> getInvoiceLineItems(Id invoiceId, List<String> additionalFieldApiNames) {
        try {
            if (invoiceId == null) {
                throw new AuraHandledException('Invoice Id is required.');
            }

            List<String> validatedFields = validateAdditionalInvoiceLineFields(additionalFieldApiNames);
            Map<String, Schema.DisplayType> fieldTypesByApiName = getValidatedInvoiceLineFieldTypes(validatedFields);
            String costFieldApi = resolveInvoiceLineCostFieldApiName();
            String taxFieldApi = resolveInvoiceLineTaxFieldApiName();
            Set<String> baseQueryFields = buildInvoiceLineBaseQueryFieldSet(costFieldApi, taxFieldApi);
            String additionalSelectClause = buildInvoiceLineSelectClause(validatedFields, baseQueryFields);

            List<String> sortFieldApiNames = resolveInvoiceLineSortOrderFieldApiNames();
            String orderByClause = buildInvoiceLineOrderByClause(sortFieldApiNames);

            String soql =
                'SELECT Id, Name, fax__Product__c, fax__Product__r.Name, fax__Product__r.ProductCode' +
                productPurchaseCostSelectClause('fax__Product__r') +
                ', fax__Qty__c, fax__Unit_Price__c, fax__Discount__c, fax__Discount_Amt__c, ' +
                'fax__Total_Amount__c, fax__Total_Amount_Excl_Tax__c, Include_In_Invoice__c, Taxable__c, Description__c' +
                (String.isBlank(costFieldApi) ? '' : ', ' + costFieldApi) +
                (String.isBlank(taxFieldApi) ? '' : ', ' + taxFieldApi) +
                buildInvoiceLineSortFieldsSelectClause(sortFieldApiNames) +
                additionalSelectClause +
                ' FROM fax__Invoice_Line_Item__c' +
                ' WHERE fax__Invoice__c = :invoiceId' +
                orderByClause;

            Id pricebookId = resolvePricebookId(invoiceId);
            List<fax__Invoice_Line_Item__c> lineItems = Database.query(soql);
            Set<Id> productIds = new Set<Id>();
            for (fax__Invoice_Line_Item__c item : lineItems) {
                if (item.fax__Product__c != null) {
                    productIds.add(item.fax__Product__c);
                }
            }
            Map<Id, Id> productIdToPbeId = mapProductIdsToPricebookEntryIds(pricebookId, productIds);

            List<LineItemRow> rows = new List<LineItemRow>();
            for (fax__Invoice_Line_Item__c item : lineItems) {
                LineItemRow row = new LineItemRow();
                row.invoiceLineItemId = item.Id;
                row.lineItemName = item.Name;
                row.productId = item.fax__Product__c;
                row.pricebookEntryId = productIdToPbeId.get(item.fax__Product__c);
                row.productName = item.fax__Product__r != null ? item.fax__Product__r.Name : null;
                row.productCode = item.fax__Product__r != null ? item.fax__Product__r.ProductCode : null;
                if (!String.isBlank(costFieldApi)) {
                    row.cost = (Decimal) item.get(costFieldApi);
                }
                if (row.cost == null) {
                    row.cost = resolveProductPurchaseCost(item.fax__Product__r);
                }
                if (!String.isBlank(taxFieldApi)) {
                    row.taxPercent = (Decimal) item.get(taxFieldApi);
                }
                row.salesPrice = item.fax__Unit_Price__c;
                row.quantity = item.fax__Qty__c;
                row.discount = item.fax__Discount__c;
                row.discountAmt = item.fax__Discount_Amt__c;
                row.subtotal = calculateSubtotal(row.quantity, row.salesPrice);
                row.amountExclTax = item.fax__Total_Amount_Excl_Tax__c;
                row.totalPrice = item.fax__Total_Amount__c != null
                    ? item.fax__Total_Amount__c
                    : calculateTotalPrice(row.quantity, row.salesPrice, row.discount);
                row.includeInInvoice = item.Include_In_Invoice__c;
                row.taxable = item.Taxable__c == true;
                row.lineItemDescription = item.Description__c;
                row.sortOrder = getInvoiceLineDecimalFieldValue(item, 'Sort_Order__c');
                row.invoiceLineFieldValues = new Map<String, String>();
                for (String fieldApiName : validatedFields) {
                    Schema.DisplayType fieldType = fieldTypesByApiName.get(fieldApiName);
                    Object rawValue = item.get(fieldApiName);
                    if (rawValue == null) {
                        rawValue = item.getPopulatedFieldsAsMap().get(fieldApiName);
                    }
                    row.invoiceLineFieldValues.put(
                        fieldApiName,
                        formatInvoiceLineFieldValue(rawValue, fieldType)
                    );
                }
                rows.add(row);
            }
            return rows;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('Unable to load Invoice Line Items. Please refresh and try again.');
        }
    }

    @AuraEnabled(cacheable=false)
    public static List<ProductOption> searchActiveProducts(Id invoiceId, String searchTerm) {
        try {
            if (invoiceId == null) {
                throw new AuraHandledException('Invoice Id is required.');
            }

            Id pricebookId = resolvePricebookId(invoiceId);
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
    public static InvoiceSummaryContext getInvoiceSummaryContext(Id invoiceId) {
        try {
            if (invoiceId == null) {
                throw new AuraHandledException('Invoice Id is required.');
            }

            InvoiceSummaryContext context = new InvoiceSummaryContext();
            fax__Invoice__c invoiceRecord = [
                SELECT Tax__c, Sub_Total_Tax_Product__c
                FROM fax__Invoice__c
                WHERE Id = :invoiceId
                LIMIT 1
            ];
            context.taxPercent = resolveInvoiceTaxPercent(invoiceId);
            context.subTotalTaxProduct = invoiceRecord.Sub_Total_Tax_Product__c != null
                ? invoiceRecord.Sub_Total_Tax_Product__c
                : 0;
            return context;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('Unable to load invoice summary details. Please refresh and try again.');
        }
    }

    @AuraEnabled
    public static void saveInvoiceLineItems(SaveRequest request) {
        try {
            validateSaveRequest(request);
            Id pricebookId = resolvePricebookId(request.invoiceId);
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
                    SELECT Id, Pricebook2Id, Product2Id, UnitPrice, Product2.faxa__Purchase_Cost__c
                    FROM PricebookEntry
                    WHERE Id IN :submittedPbeIds
                ]) {
                    pbeById.put(pbe.Id, pbe);
                }
            }

            String costFieldApi = resolveInvoiceLineCostFieldApiName();
            String taxFieldApi = resolveInvoiceLineTaxFieldApiName();
            List<String> sortFieldApiNames = resolveInvoiceLineSortOrderFieldApiNames();
            List<fax__Invoice_Line_Item__c> toUpsert = new List<fax__Invoice_Line_Item__c>();
            for (Integer index = 0; index < rows.size(); index++) {
                LineItemRow row = rows[index];
                validateRow(row, index, pbeById, pricebookId);
                PricebookEntry selectedPbe = row.pricebookEntryId != null
                    ? pbeById.get(row.pricebookEntryId)
                    : null;
                Id productId = row.productId != null
                    ? row.productId
                    : (selectedPbe != null ? selectedPbe.Product2Id : null);

                fax__Invoice_Line_Item__c line = new fax__Invoice_Line_Item__c();
                if (row.invoiceLineItemId != null) {
                    line.Id = row.invoiceLineItemId;
                }

                line.fax__Qty__c = row.quantity;
                line.fax__Unit_Price__c = row.salesPrice;
                line.fax__Discount__c = row.discount;
                line.Include_In_Invoice__c = row.includeInInvoice == null ? true : row.includeInInvoice;
                line.Description__c = row.lineItemDescription;

                if (!String.isBlank(costFieldApi)) {
                    Decimal costValue = row.cost != null
                        ? row.cost
                        : (selectedPbe != null ? resolveProductPurchaseCost(selectedPbe.Product2) : null);
                    if (costValue != null) {
                        line.put(costFieldApi, costValue);
                    }
                }

                if (!String.isBlank(taxFieldApi) && !taxFieldApi.equalsIgnoreCase('fax__Tax__c') && row.taxPercent != null) {
                    line.put(taxFieldApi, row.taxPercent);
                }

                if (row.invoiceLineItemId == null) {
                    line.fax__Invoice__c = request.invoiceId;
                    line.fax__Product__c = productId;
                }

                if (!sortFieldApiNames.isEmpty()) {
                    Decimal sortValue = index + 1;
                    for (String sortFieldApi : sortFieldApiNames) {
                        line.put(sortFieldApi, sortValue);
                    }
                }

                toUpsert.add(line);
            }

            if (!toUpsert.isEmpty()) {
                upsert toUpsert;

                if (!sortFieldApiNames.isEmpty()) {
                    List<fax__Invoice_Line_Item__c> sortOrderUpdates = new List<fax__Invoice_Line_Item__c>();
                    for (fax__Invoice_Line_Item__c lineItem : toUpsert) {
                        if (lineItem.Id == null) {
                            continue;
                        }
                        fax__Invoice_Line_Item__c sortUpdate = new fax__Invoice_Line_Item__c(
                            Id = lineItem.Id
                        );
                        Boolean hasSortValue = false;
                        for (String sortFieldApi : sortFieldApiNames) {
                            Object sortValue = lineItem.get(sortFieldApi);
                            if (sortValue != null) {
                                sortUpdate.put(sortFieldApi, sortValue);
                                hasSortValue = true;
                            }
                        }
                        if (hasSortValue) {
                            sortOrderUpdates.add(sortUpdate);
                        }
                    }
                    if (!sortOrderUpdates.isEmpty()) {
                        update sortOrderUpdates;
                    }
                }
            }

            if (!deletedIds.isEmpty()) {
                List<fax__Invoice_Line_Item__c> toDelete = [
                    SELECT Id
                    FROM fax__Invoice_Line_Item__c
                    WHERE Id IN :deletedIds
                      AND fax__Invoice__c = :request.invoiceId
                ];
                if (!toDelete.isEmpty()) {
                    delete toDelete;
                }
            }
        } catch (AuraHandledException e) {
            throw e;
        } catch (DmlException e) {
            throw new AuraHandledException(buildDmlMessage(e));
        } catch (Exception e) {
            throw new AuraHandledException('Unable to save invoice lines. Please verify values and try again.');
        }
    }

    private static void validateSaveRequest(SaveRequest request) {
        if (request == null) {
            throw new AuraHandledException('Save request is required.');
        }
        if (request.invoiceId == null) {
            throw new AuraHandledException('Invoice Id is required.');
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
        if (row.pricebookEntryId == null && row.productId == null) {
            throw new AuraHandledException('Row ' + displayRow + ': Product is required.');
        }
        if (row.pricebookEntryId != null) {
            PricebookEntry pbe = pbeById.get(row.pricebookEntryId);
            if (pbe == null || pbe.Pricebook2Id != expectedPricebookId) {
                throw new AuraHandledException('Row ' + displayRow + ': Selected product is not valid for this Invoice.');
            }
        } else if (row.invoiceLineItemId == null) {
            throw new AuraHandledException('Row ' + displayRow + ': Product is required.');
        }
        if (row.quantity == null || row.quantity <= 0) {
            throw new AuraHandledException('Row ' + displayRow + ': Quantity must be greater than zero.');
        }
       /* if (row.salesPrice == null || row.salesPrice < 0) {
            throw new AuraHandledException('Row ' + displayRow + ': Sales Price cannot be negative.');
        }*/
    }

    private static Decimal calculateSubtotal(Decimal quantity, Decimal unitPrice) {
        Decimal qty = quantity == null ? 0 : quantity;
        Decimal price = unitPrice == null ? 0 : unitPrice;
        return qty * price;
    }

    private static Decimal calculateTotalPrice(Decimal quantity, Decimal unitPrice, Decimal discount) {
        Decimal amount = calculateSubtotal(quantity, unitPrice);
        Decimal discountPct = discount == null ? 0 : discount;
        if (discountPct != 0) {
            amount = amount - (amount * discountPct / 100);
        }
        return amount.setScale(2);
    }

    private static Map<Id, Id> mapProductIdsToPricebookEntryIds(Id pricebookId, Set<Id> productIds) {
        Map<Id, Id> productIdToPbeId = new Map<Id, Id>();
        if (pricebookId == null || productIds == null || productIds.isEmpty()) {
            return productIdToPbeId;
        }
        for (PricebookEntry pbe : [
            SELECT Id, Product2Id
            FROM PricebookEntry
            WHERE Pricebook2Id = :pricebookId
              AND Product2Id IN :productIds
              AND IsActive = TRUE
        ]) {
            productIdToPbeId.put(pbe.Product2Id, pbe.Id);
        }
        return productIdToPbeId;
    }

    private static String resolveInvoiceLineCostFieldApiName() {
        Map<String, Schema.SObjectField> fieldMap = Schema.SObjectType.fax__Invoice_Line_Item__c.fields.getMap();
        for (String candidate : new List<String>{ 'Cost__c', 'fax__Cost__c' }) {
            if (fieldMap.containsKey(candidate) && fieldMap.get(candidate).getDescribe().isUpdateable()) {
                return candidate;
            }
        }
        return null;
    }

    private static String resolveInvoiceLineTaxFieldApiName() {
        Map<String, Schema.SObjectField> fieldMap = Schema.SObjectType.fax__Invoice_Line_Item__c.fields.getMap();
        if (fieldMap.containsKey('fax__Tax__c') && fieldMap.get('fax__Tax__c').getDescribe().isAccessible()) {
            return 'fax__Tax__c';
        }
        return null;
    }

    private static List<String> resolveInvoiceLineSortOrderFieldApiNames() {
        Map<String, Schema.SObjectField> fieldMap = Schema.SObjectType.fax__Invoice_Line_Item__c.fields.getMap();
        List<String> sortFieldApiNames = new List<String>();
        for (String candidate : new List<String>{ 'Sort_Order__c' }) {
            String fieldKey = resolveInvoiceLineFieldMapKey(candidate, fieldMap);
            if (fieldKey == null) {
                continue;
            }
            Schema.DescribeFieldResult describe = fieldMap.get(fieldKey).getDescribe();
            if (describe.isUpdateable()) {
                sortFieldApiNames.add(describe.getName());
            }
        }
        return sortFieldApiNames;
    }

    private static String buildInvoiceLineOrderByClause(List<String> sortFieldApiNames) {
        if (sortFieldApiNames == null || sortFieldApiNames.isEmpty()) {
            return ' ORDER BY CreatedDate ASC';
        }

        List<String> orderParts = new List<String>();
        for (String sortFieldApi : sortFieldApiNames) {
            orderParts.add(sortFieldApi + ' ASC NULLS LAST');
        }
        orderParts.add('CreatedDate ASC');
        return ' ORDER BY ' + String.join(orderParts, ', ');
    }

    private static String buildInvoiceLineSortFieldsSelectClause(List<String> sortFieldApiNames) {
        if (sortFieldApiNames == null || sortFieldApiNames.isEmpty()) {
            return '';
        }

        return ', ' + String.join(sortFieldApiNames, ', ');
    }

    private static Decimal getInvoiceLineDecimalFieldValue(
        fax__Invoice_Line_Item__c lineItem,
        String fieldApiName
    ) {
        if (lineItem == null || String.isBlank(fieldApiName)) {
            return null;
        }

        Map<String, Schema.SObjectField> fieldMap = Schema.SObjectType.fax__Invoice_Line_Item__c.fields.getMap();
        String fieldKey = resolveInvoiceLineFieldMapKey(fieldApiName, fieldMap);
        if (fieldKey == null || !fieldMap.get(fieldKey).getDescribe().isAccessible()) {
            return null;
        }

        Object rawValue = lineItem.get(fieldMap.get(fieldKey).getDescribe().getName());
        return rawValue instanceof Decimal ? (Decimal) rawValue : null;
    }

    private static String resolveInvoiceLineTaxAmountFieldApiName() {
        Map<String, Schema.SObjectField> fieldMap = Schema.SObjectType.fax__Invoice_Line_Item__c.fields.getMap();
        if (
            fieldMap.containsKey('fax__Tax_Amount__c') &&
            fieldMap.get('fax__Tax_Amount__c').getDescribe().isAccessible()
        ) {
            return 'fax__Tax_Amount__c';
        }
        return null;
    }

    private static List<String> validateAdditionalInvoiceLineFields(List<String> requestedFieldApiNames) {
        List<String> validated = new List<String>();
        if (requestedFieldApiNames == null || requestedFieldApiNames.isEmpty()) {
            return validated;
        }

        Map<String, Schema.SObjectField> fieldMap = Schema.SObjectType.fax__Invoice_Line_Item__c.fields.getMap();
        Set<String> seenLower = new Set<String>();
        for (String requestedApiName : requestedFieldApiNames) {
            if (String.isBlank(requestedApiName)) {
                continue;
            }
            String canonicalApiName = resolveInvoiceLineFieldApiName(requestedApiName, fieldMap);
            if (canonicalApiName == null) {
                continue;
            }
            String seenKey = canonicalApiName.toLowerCase();
            if (seenLower.contains(seenKey)) {
                continue;
            }
            if (isReservedInvoiceLineField(canonicalApiName) || isDefaultInvoiceLineTableField(canonicalApiName)) {
                continue;
            }
            Schema.SObjectField fieldToken = fieldMap.get(resolveInvoiceLineFieldMapKey(canonicalApiName, fieldMap));
            Schema.DescribeFieldResult describe = fieldToken.getDescribe();
            if (!describe.isAccessible() || !SELECTABLE_INVOICE_LINE_FIELD_TYPES.contains(describe.getType())) {
                continue;
            }
            seenLower.add(seenKey);
            validated.add(canonicalApiName);
        }
        return validated;
    }

    private static Map<String, Schema.DisplayType> getValidatedInvoiceLineFieldTypes(List<String> validatedFields) {
        Map<String, Schema.DisplayType> fieldTypesByApiName = new Map<String, Schema.DisplayType>();
        Map<String, Schema.SObjectField> fieldMap = Schema.SObjectType.fax__Invoice_Line_Item__c.fields.getMap();
        for (String fieldApiName : validatedFields) {
            String fieldKey = resolveInvoiceLineFieldMapKey(fieldApiName, fieldMap);
            fieldTypesByApiName.put(fieldApiName, fieldMap.get(fieldKey).getDescribe().getType());
        }
        return fieldTypesByApiName;
    }

    private static String resolveInvoiceLineFieldApiName(
        String requestedApiName,
        Map<String, Schema.SObjectField> fieldMap
    ) {
        if (String.isBlank(requestedApiName)) {
            return null;
        }
        String fieldKey = resolveInvoiceLineFieldMapKey(requestedApiName, fieldMap);
        return fieldKey == null ? null : fieldMap.get(fieldKey).getDescribe().getName();
    }

    private static String resolveInvoiceLineFieldMapKey(
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

    private static Boolean isDefaultInvoiceLineTableField(String apiName) {
        if (String.isBlank(apiName)) {
            return false;
        }
        for (String defaultApiName : DEFAULT_INVOICE_LINE_TABLE_FIELD_API_NAMES) {
            if (defaultApiName.equalsIgnoreCase(apiName)) {
                return true;
            }
        }
        return false;
    }

    private static Boolean isReservedInvoiceLineField(String apiName) {
        if (String.isBlank(apiName)) {
            return false;
        }
        for (String reservedApiName : RESERVED_INVOICE_LINE_FIELD_API_NAMES) {
            if (reservedApiName.equalsIgnoreCase(apiName)) {
                return true;
            }
        }
        return false;
    }

    private static final Set<String> INVOICE_LINE_BASE_QUERY_FIELD_API_NAMES = new Set<String>{
        'Id',
        'Name',
        'fax__Product__c',
        'fax__Qty__c',
        'fax__Unit_Price__c',
        'fax__Discount__c',
        'fax__Discount_Amt__c',
        'fax__Total_Amount__c',
        'fax__Total_Amount_Excl_Tax__c',
        'Include_In_Invoice__c',
        'Taxable__c',
        'Description__c',
        'Cost__c',
        'fax__Cost__c',
        'fax__Tax__c'
    };

    private static Set<String> buildInvoiceLineBaseQueryFieldSet(String costFieldApi, String taxFieldApi) {
        Set<String> baseQueryFields = new Set<String>();
        for (String fieldApiName : INVOICE_LINE_BASE_QUERY_FIELD_API_NAMES) {
            baseQueryFields.add(fieldApiName.toLowerCase());
        }
        if (!String.isBlank(costFieldApi)) {
            baseQueryFields.add(costFieldApi.toLowerCase());
        }
        if (!String.isBlank(taxFieldApi)) {
            baseQueryFields.add(taxFieldApi.toLowerCase());
        }
        return baseQueryFields;
    }

    private static Boolean isInvoiceLineBaseQueryField(String fieldApiName, Set<String> baseQueryFields) {
        return !String.isBlank(fieldApiName) &&
            baseQueryFields != null &&
            baseQueryFields.contains(fieldApiName.toLowerCase());
    }

    private static String buildInvoiceLineSelectClause(
        List<String> validatedFields,
        Set<String> baseQueryFields
    ) {
        if (validatedFields == null || validatedFields.isEmpty()) {
            return '';
        }
        List<String> selectParts = new List<String>();
        Set<String> seenLower = new Set<String>();
        for (String fieldApiName : validatedFields) {
            if (String.isBlank(fieldApiName) || isInvoiceLineBaseQueryField(fieldApiName, baseQueryFields)) {
                continue;
            }
            String seenKey = fieldApiName.toLowerCase();
            if (seenLower.contains(seenKey)) {
                continue;
            }
            seenLower.add(seenKey);
            selectParts.add(fieldApiName);
        }
        if (selectParts.isEmpty()) {
            return '';
        }
        return ', ' + String.join(selectParts, ', ');
    }

    private static String formatInvoiceLineFieldValue(Object rawValue, Schema.DisplayType fieldType) {
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

    private static String productPurchaseCostSelectClause(String productRelationshipPrefix) {
        if (!productHasPurchaseCostField()) {
            return '';
        }
        String prefix = String.isBlank(productRelationshipPrefix) ? 'Product2' : productRelationshipPrefix;
        return ', ' + prefix + '.' + PRODUCT_PURCHASE_COST_FIELD;
    }

    private static Decimal resolveProductPurchaseCost(SObject productRecord) {
        if (productRecord == null || !productHasPurchaseCostField()) {
            return null;
        }
        return (Decimal) productRecord.get(PRODUCT_PURCHASE_COST_FIELD);
    }

    private static String buildProductSearchSelectFields() {
        return 'Id, UnitPrice, Product2Id, Product2.Name, Product2.ProductCode, Product2.Description, Product2.Is_Taxable__c' +
            productPurchaseCostSelectClause('Product2');
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
        option.taxable = pbe.Product2 != null && pbe.Product2.Is_Taxable__c == true;
        return option;
    }

    private static Decimal resolveInvoiceTaxPercent(Id invoiceId) {
        fax__Invoice__c invoiceRecord = [
            SELECT Id, Tax__c, fax__Site__c
            FROM fax__Invoice__c
            WHERE Id = :invoiceId
            LIMIT 1
        ];

        if (invoiceRecord.fax__Site__c == null) {
            return invoiceRecord.Tax__c != null ? invoiceRecord.Tax__c : 0;
        }

        List<Account> accounts = [
            SELECT Tax_Group_Code__c
            FROM Account
            WHERE Id = :invoiceRecord.fax__Site__c
            LIMIT 1
        ];
        if (accounts.isEmpty() || accounts[0].Tax_Group_Code__c == null) {
            return invoiceRecord.Tax__c != null ? invoiceRecord.Tax__c : 0;
        }

        List<faxa__Tax__c> taxGroups = [
            SELECT faxa__Percentage__c
            FROM faxa__Tax__c
            WHERE Id = :accounts[0].Tax_Group_Code__c
            LIMIT 1
        ];
        if (taxGroups.isEmpty() || taxGroups[0].faxa__Percentage__c == null) {
            return invoiceRecord.Tax__c != null ? invoiceRecord.Tax__c : 0;
        }

        return taxGroups[0].faxa__Percentage__c;
    }

    private static Id resolvePricebookId(Id invoiceId) {
        if (!Schema.sObjectType.fax__Invoice__c.isAccessible()) {
            throw new AuraHandledException('You do not have access to Invoice records.');
        }

        Map<String, Schema.SObjectField> invoiceFieldMap = Schema.SObjectType.fax__Invoice__c.fields.getMap();
        if (invoiceFieldMap.containsKey(INVOICE_PRICEBOOK_FIELD)
            && invoiceFieldMap.get(INVOICE_PRICEBOOK_FIELD).getDescribe().isAccessible()) {
            String soql = 'SELECT Id, ' + INVOICE_PRICEBOOK_FIELD + ' FROM fax__Invoice__c WHERE Id = :invoiceId LIMIT 1';
            fax__Invoice__c invoiceRecord = (fax__Invoice__c) Database.query(soql);
            Id pricebookId = (Id) invoiceRecord.get(INVOICE_PRICEBOOK_FIELD);
            if (pricebookId != null) {
                return pricebookId;
            }
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
            'No active Price Book is associated with this Invoice. Set a Price Book on the Invoice or activate the Standard Price Book.'
        );
    }

    private static String buildDmlMessage(DmlException e) {
        if (e == null) {
            return 'Unable to save invoice lines due to a data error.';
        }
        List<String> messages = new List<String>();
        for (Integer i = 0; i < e.getNumDml(); i++) {
            String msg = e.getDmlMessage(i);
            if (!String.isBlank(msg)) {
                messages.add(msg);
            }
        }
        if (!messages.isEmpty()) {
            return String.join(messages, ' ');
        }
        return 'Unable to save invoice lines due to a data error.';
    }
}