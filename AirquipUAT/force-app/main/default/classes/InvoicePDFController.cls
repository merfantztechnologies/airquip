public class InvoicePDFController {
    public fax__Invoice__c invoice { get; set; }
    public List<PreviewColumnDefinition> previewColumns { get; set; }
    public List<DynamicLineItemRow> lineItemRows { get; set; }
    public Integer previewColumnCount { get; set; }

    // Kept for backward compatibility with any existing references/tests.
    public List<LineItemWrapper> lineItems { get; set; }

    public class PreviewColumnDefinition {
        public String key { get; set; }
        public String label { get; set; }
        public String fieldPath { get; set; }
        public Integer widthPercent { get; set; }
        public String headerAlignment { get; set; }
        public String cellAlignment { get; set; }
        public String formatType { get; set; }
    }

    public class PreviewCell {
        public String alignment { get; set; }
        public String cssClass { get; set; }
        public String displayValue { get; set; }
        public String htmlValue { get; set; }
        public Decimal numericValue { get; set; }
        public Boolean isProduct { get; set; }
        public Boolean isDescription { get; set; }
        public Boolean isQuantity { get; set; }
        public Boolean isCurrency { get; set; }
        public Boolean isText { get; set; }
    }

    public class DynamicLineItemRow {
        public List<PreviewCell> cells { get; set; }

        public DynamicLineItemRow() {
            cells = new List<PreviewCell>();
        }
    }

    public class LineItemWrapper {
        public String wrappedProductName { get; set; }
        public Decimal qty { get; set; }
        public String description { get; set; }
        public String formattedDescription { get; set; }
        public Decimal unitPrice { get; set; }
        public Decimal totalAmount { get; set; }

        public LineItemWrapper(fax__Invoice_Line_Item__c item) {
            this.qty = item.fax__Qty__c;
            this.description = item.Description__c;
            this.formattedDescription = formatDescription(item.Description__c);
            this.unitPrice = item.fax__Unit_Price__c;
            this.totalAmount = item.fax__Total_Amount__c;
            this.wrappedProductName = String.isBlank(item.fax__Product__r.Name)
                ? ''
                : wrapAtWordBoundary(item.fax__Product__r.Name, 16);
        }
    }

    public InvoicePDFController() {
        Id invId = ApexPages.currentPage().getParameters().get('id');
        if (invId == null) {
            throw new AuraHandledException('Invoice Id is required.');
        }

        invoice = [
            SELECT Id, Name,
                fax__site__r.Name,
                fax__Date__c,
                fax__Terms__c,
                fax__PO_Number__c,
                fax__Job__r.Name,
                Sub_Total__c,
                Tax__c,
                Sub_Total_Tax_Product__c,
                Grand_Total__c,
                Payment_Received__c,
                Amount_Due__c,
                fax__City__c,
                fax__Street__c,
                fax__State__c,
                fax__Postal_Code__c,
                fax__Site__r.ShippingStreet,
                fax__Site__r.ShippingCity,
                fax__Site__r.ShippingState,
                fax__Site__r.ShippingPostalCode,
                fax__Site__r.ShippingCountry,
                CreatedDate
            FROM fax__Invoice__c
            WHERE Id = :invId
        ];

        previewColumns = resolvePreviewColumns();
        previewColumnCount = previewColumns.size();

        List<fax__Invoice_Line_Item__c> rawItems = loadLineItems(invId, previewColumns);

        lineItemRows = new List<DynamicLineItemRow>();
        lineItems = new List<LineItemWrapper>();
        for (fax__Invoice_Line_Item__c item : rawItems) {
            lineItemRows.add(buildDynamicRow(item, previewColumns));
            lineItems.add(new LineItemWrapper(item));
        }
    }

    private static List<PreviewColumnDefinition> resolvePreviewColumns() {
        return getDefaultPreviewColumns();
    }

    private static List<PreviewColumnDefinition> getDefaultPreviewColumns() {
        return new List<PreviewColumnDefinition>{
            buildDefaultColumn('quantity', 'Quantity', 'fax__Qty__c', 8, 'center', 'right', 'quantity'),
            buildDefaultColumn('item', 'Item', 'fax__Product__r.Name', 17, 'center', 'left', 'product'),
            buildDefaultColumn('description', 'Description', 'Description__c', 45, 'center', 'left', 'description'),
            buildDefaultColumn('price', 'Price', 'fax__Unit_Price__c', 15, 'center', 'right', 'currency'),
            buildDefaultColumn('amount', 'Amount', 'fax__Total_Amount__c', 15, 'center', 'right', 'currency')
        };
    }

    private static PreviewColumnDefinition buildDefaultColumn(
        String key,
        String label,
        String fieldPath,
        Integer widthPercent,
        String headerAlignment,
        String cellAlignment,
        String formatType
    ) {
        PreviewColumnDefinition column = new PreviewColumnDefinition();
        column.key = key;
        column.label = label;
        column.fieldPath = fieldPath;
        column.widthPercent = widthPercent;
        column.headerAlignment = headerAlignment;
        column.cellAlignment = cellAlignment;
        column.formatType = formatType;
        return column;
    }

    private static List<fax__Invoice_Line_Item__c> loadLineItems(
        Id invoiceId,
        List<PreviewColumnDefinition> columns
    ) {
        Set<String> selectFields = new Set<String>();
        for (PreviewColumnDefinition column : columns) {
            if (isValidPreviewFieldPath(column.fieldPath)) {
                selectFields.add(column.fieldPath);
            }
        }

        if (selectFields.isEmpty()) {
            selectFields.add('fax__Qty__c');
            selectFields.add('Description__c');
            selectFields.add('fax__Unit_Price__c');
            selectFields.add('fax__Total_Amount__c');
            selectFields.add('fax__Product__r.Name');
        }

        List<String> sortFieldApiNames = resolveLineItemSortFieldApiNames();
        for (String sortFieldApi : sortFieldApiNames) {
            selectFields.add(sortFieldApi);
        }

        List<String> orderedSelectFields = new List<String>(selectFields);
        orderedSelectFields.sort();

        String soql =
            'SELECT ' +
            String.join(orderedSelectFields, ', ') +
            ' FROM fax__Invoice_Line_Item__c' +
            ' WHERE fax__Invoice__c = :invoiceId' +
            ' AND Include_In_Invoice__c = true' +
            buildLineItemOrderByClause(sortFieldApiNames);

        return Database.query(soql);
    }

    private static List<String> resolveLineItemSortFieldApiNames() {
        Map<String, Schema.SObjectField> fieldMap = Schema.SObjectType.fax__Invoice_Line_Item__c.fields.getMap();
        List<String> sortFieldApiNames = new List<String>();
        for (String candidate : new List<String>{ 'Sort_Order__c' }) {
            String fieldKey = resolveFieldMapKey(candidate, fieldMap);
            if (fieldKey == null) {
                continue;
            }
            Schema.DescribeFieldResult describe = fieldMap.get(fieldKey).getDescribe();
            if (describe.isAccessible()) {
                sortFieldApiNames.add(describe.getName());
            }
        }
        return sortFieldApiNames;
    }

    private static String buildLineItemOrderByClause(List<String> sortFieldApiNames) {
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

    private static DynamicLineItemRow buildDynamicRow(
        fax__Invoice_Line_Item__c item,
        List<PreviewColumnDefinition> columns
    ) {
        DynamicLineItemRow row = new DynamicLineItemRow();
        for (PreviewColumnDefinition column : columns) {
            row.cells.add(buildPreviewCell(item, column));
        }
        return row;
    }

    private static PreviewCell buildPreviewCell(
        fax__Invoice_Line_Item__c item,
        PreviewColumnDefinition column
    ) {
        PreviewCell cell = new PreviewCell();
        cell.alignment = column.cellAlignment;
        cell.cssClass = column.formatType == 'description' ? '' : '';
        Object rawValue = getFieldValue(item, column.fieldPath);
        String formatType = column.formatType;

        cell.isProduct = formatType == 'product';
        cell.isDescription = formatType == 'description';
        cell.isQuantity = formatType == 'quantity';
        cell.isCurrency = formatType == 'currency';
        cell.isText = !cell.isProduct && !cell.isDescription && !cell.isQuantity && !cell.isCurrency;

        if (cell.isProduct) {
            String productName = rawValue == null ? '' : String.valueOf(rawValue);
            cell.htmlValue = String.isBlank(productName) ? '' : wrapAtWordBoundary(productName, 16);
            cell.cssClass = 'product-cell';
            return cell;
        }

        if (cell.isDescription) {
            cell.displayValue = rawValue == null ? '' : String.valueOf(rawValue);
            return cell;
        }

        if (cell.isQuantity || cell.isCurrency) {
            cell.numericValue = toDecimal(rawValue);
            return cell;
        }

        cell.displayValue = formatTextValue(rawValue);
        return cell;
    }

    private static Object getFieldValue(SObject record, String fieldPath) {
        if (record == null || String.isBlank(fieldPath)) {
            return null;
        }

        List<String> pathParts = fieldPath.split('\\.');
        SObject currentRecord = record;
        for (Integer index = 0; index < pathParts.size(); index++) {
            String pathPart = pathParts[index];
            if (index == pathParts.size() - 1) {
                return currentRecord.get(pathPart);
            }

            currentRecord = currentRecord.getSObject(pathPart);
            if (currentRecord == null) {
                return null;
            }
        }

        return null;
    }

    private static Decimal toDecimal(Object rawValue) {
        if (rawValue == null) {
            return 0;
        }
        if (rawValue instanceof Decimal) {
            return (Decimal) rawValue;
        }
        if (rawValue instanceof Integer) {
            return Decimal.valueOf((Integer) rawValue);
        }
        if (rawValue instanceof Long) {
            return Decimal.valueOf((Long) rawValue);
        }
        if (rawValue instanceof Double) {
            return Decimal.valueOf((Double) rawValue);
        }
        try {
            return Decimal.valueOf(String.valueOf(rawValue));
        } catch (Exception e) {
            return 0;
        }
    }

    private static String formatTextValue(Object rawValue) {
        if (rawValue == null) {
            return '';
        }
        if (rawValue instanceof Boolean) {
            return ((Boolean) rawValue) ? 'Yes' : 'No';
        }
        if (rawValue instanceof Date) {
            return ((Date) rawValue).format();
        }
        if (rawValue instanceof Datetime) {
            return ((Datetime) rawValue).format('MM/dd/yyyy h:mm a');
        }
        return String.valueOf(rawValue);
    }

    private static String normalizeAlignment(String alignment, String fallback) {
        if (String.isBlank(alignment)) {
            return fallback;
        }
        String normalized = alignment.trim().toLowerCase();
        if (normalized == 'left' || normalized == 'center' || normalized == 'right') {
            return normalized;
        }
        return fallback;
    }

    private static Boolean isValidPreviewFieldPath(String fieldPath) {
        if (String.isBlank(fieldPath)) {
            return false;
        }

        List<String> pathParts = fieldPath.split('\\.');
        if (pathParts.isEmpty()) {
            return false;
        }

        Map<String, Schema.SObjectField> currentFieldMap = Schema.SObjectType.fax__Invoice_Line_Item__c.fields.getMap();

        for (Integer index = 0; index < pathParts.size(); index++) {
            String pathPart = pathParts[index];
            String fieldKey = resolveRelationshipFieldKey(pathPart, currentFieldMap);
            if (fieldKey == null) {
                return false;
            }

            Schema.DescribeFieldResult describe = currentFieldMap.get(fieldKey).getDescribe();
            if (index == pathParts.size() - 1) {
                return describe.isAccessible();
            }

            if (describe.getType() != Schema.DisplayType.REFERENCE) {
                return false;
            }

            List<Schema.SObjectType> referenceTo = describe.getReferenceTo();
            if (referenceTo.isEmpty()) {
                return false;
            }

            currentFieldMap = referenceTo[0].getDescribe().fields.getMap();
        }

        return false;
    }

    private static String resolveRelationshipFieldKey(
        String pathPart,
        Map<String, Schema.SObjectField> fieldMap
    ) {
        String fieldKey = resolveFieldMapKey(pathPart, fieldMap);
        if (fieldKey != null) {
            return fieldKey;
        }

        if (pathPart != null && pathPart.endsWith('__r')) {
            return resolveFieldMapKey(pathPart.substring(0, pathPart.length() - 3) + '__c', fieldMap);
        }

        return null;
    }

    private static String resolveFieldMapKey(String fieldApiName, Map<String, Schema.SObjectField> fieldMap) {
        if (String.isBlank(fieldApiName) || fieldMap == null) {
            return null;
        }
        if (fieldMap.containsKey(fieldApiName)) {
            return fieldApiName;
        }
        String lowerFieldApiName = fieldApiName.toLowerCase();
        for (String fieldKey : fieldMap.keySet()) {
            if (fieldKey != null && fieldKey.toLowerCase() == lowerFieldApiName) {
                return fieldKey;
            }
        }
        return null;
    }

    private static String formatDescription(String sourceText) {
        if (String.isBlank(sourceText)) {
            return '';
        }

        String normalized = sourceText.replace('\r\n', '\n');
        normalized = normalized.replace('\r', '\n');
        normalized = normalized.replace('\t', ' ');

        List<String> lines = normalized.split('\n');
        String formatted = '';
        Boolean previousLineWasBlank = false;

        for (String line : lines) {
            String trimmedLine = line == null ? '' : line.trim();

            if (trimmedLine == '') {
                if (formatted != '' && !previousLineWasBlank) {
                    formatted += '<br/><br/>';
                }
                previousLineWasBlank = true;
                continue;
            }

            if (formatted != '' && !previousLineWasBlank) {
                formatted += ' ';
            }

            formatted += trimmedLine.escapeHtml4();
            previousLineWasBlank = false;
        }

        formatted = formatted.replace('. ', '.<br/>');
        return formatted;
    }

    private static String wrapAtWordBoundary(String name, Integer maxChars) {
        if (String.isBlank(name)) {
            return '';
        }

        String result = '';
        String remaining = name;

        while (remaining.length() > 0) {
            if (remaining.length() <= maxChars) {
                // Escape user text so names like "<00504-054" render as text; keep <br/> for PDF wrapping
                result += remaining.escapeHtml4();
                break;
            }

            Integer breakIndex = -1;
            for (Integer i = Math.min(maxChars, remaining.length() - 1); i >= 1; i--) {
                String ch = remaining.substring(i - 1, i);
                if (ch == '@' || ch == '-' || ch == '/' || ch == ' ') {
                    breakIndex = i;
                    break;
                }
            }

            if (breakIndex == -1) {
                result += remaining.substring(0, maxChars).escapeHtml4() + '<br/>';
                remaining = remaining.substring(maxChars);
            } else {
                result += remaining.substring(0, breakIndex).escapeHtml4() + '<br/>';
                remaining = remaining.substring(breakIndex);
                if (remaining.startsWith(' ')) {
                    remaining = remaining.substring(1);
                }
            }
        }

        return result;
    }
}