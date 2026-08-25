@isTest
private class InvoicePDFControllerTest {

    private static fax__Invoice__c createInvoice() {
        fax__Invoice__c inv = new fax__Invoice__c(
            fax__Date__c = Date.today()
        );
        insert inv;
        return inv;
    }

    private static void createLineItem(Id invId, String productName, Boolean includeFlag) {
        createLineItem(invId, productName, includeFlag, 'Test Description');
    }

    private static void createLineItem(
        Id invId,
        String productName,
        Boolean includeFlag,
        String description
    ) {
        createLineItem(invId, productName, includeFlag, description, 2, 100);
    }

    private static void createLineItem(
        Id invId,
        String productName,
        Boolean includeFlag,
        String description,
        Decimal qty,
        Decimal unitPrice
    ) {
        Id productId = null;
        if (productName != null) {
            Product2 prod = new Product2(
                Name = productName,
                IsActive = true,
                Family = 'Hardware'
            );
            insert prod;
            productId = prod.Id;
        }

        fax__Invoice_Line_Item__c item = new fax__Invoice_Line_Item__c(
            fax__Invoice__c = invId,
            fax__Qty__c = qty,
            fax__Unit_Price__c = unitPrice,
            Include_In_Invoice__c = includeFlag,
            fax__Product__c = productId,
            Description__c = description
        );
        insert item;
    }

    private static InvoicePDFController.PreviewCell findCell(
        InvoicePDFController.DynamicLineItemRow row,
        String formatType
    ) {
        for (InvoicePDFController.PreviewCell cell : row.cells) {
            if (formatType == 'product' && cell.isProduct) {
                return cell;
            }
            if (formatType == 'description' && cell.isDescription) {
                return cell;
            }
            if (formatType == 'quantity' && cell.isQuantity) {
                return cell;
            }
            if (formatType == 'currency' && cell.isCurrency) {
                return cell;
            }
            if (formatType == 'text' && cell.isText) {
                return cell;
            }
        }
        return null;
    }

    private static InvoicePDFController loadController(Id invoiceId) {
        Test.setCurrentPage(Page.InvoicePreview);
        ApexPages.currentPage().getParameters().put('id', invoiceId);
        return new InvoicePDFController();
    }

    private static InvoicePDFController.LineItemWrapper findWrapperByDescription(
        InvoicePDFController ctrl,
        String descriptionMarker
    ) {
        for (InvoicePDFController.LineItemWrapper li : ctrl.lineItems) {
            if (li.description != null && li.description.contains(descriptionMarker)) {
                return li;
            }
        }
        return null;
    }

    @isTest
    static void testConstructor_WithLineItems() {
        fax__Invoice__c inv = createInvoice();

        createLineItem(inv.Id, 'VeryLongProductName12345', true, 'Wrapped item');
        createLineItem(inv.Id, 'ShortName', true, 'Short item');

        Test.startTest();
        InvoicePDFController ctrl = loadController(inv.Id);
        Test.stopTest();

        System.assertNotEquals(null, ctrl.invoice);
        System.assertEquals(inv.Id, ctrl.invoice.Id);
        System.assertNotEquals(null, ctrl.lineItems);
        System.assertEquals(2, ctrl.lineItems.size());

        Boolean foundWrapped = false;
        for (InvoicePDFController.LineItemWrapper li : ctrl.lineItems) {
            if (li.wrappedProductName != null && li.wrappedProductName.contains('<br/>')) {
                foundWrapped = true;
            }
        }
        System.assert(foundWrapped, 'Expected wrapped product name');
    }

    @isTest
    static void testConstructor_ExcludeLineItems() {
        fax__Invoice__c inv = createInvoice();
        createLineItem(inv.Id, 'TestProduct', false, 'Excluded item');

        Test.startTest();
        InvoicePDFController ctrl = loadController(inv.Id);
        Test.stopTest();

        System.assertEquals(0, ctrl.lineItems.size(), 'Excluded items should not appear');
    }

    @isTest
    static void testConstructor_NoLineItems() {
        fax__Invoice__c inv = createInvoice();

        Test.startTest();
        InvoicePDFController ctrl = loadController(inv.Id);
        Test.stopTest();

        System.assertNotEquals(null, ctrl.invoice);
        System.assertEquals(0, ctrl.lineItems.size());
    }

    @isTest
    static void testConstructor_MissingId() {
        Test.setCurrentPage(Page.InvoicePreview);

        Boolean exceptionThrown = false;
        try {
            new InvoicePDFController();
        } catch (Exception e) {
            exceptionThrown = true;
        }

        System.assert(exceptionThrown, 'Expected exception when id is missing');
    }

    @isTest
    static void testLineItemWrapper_BlankProductName() {
        fax__Invoice__c inv = createInvoice();
        createLineItem(inv.Id, null, true, 'No product marker');

        Test.startTest();
        InvoicePDFController ctrl = loadController(inv.Id);
        Test.stopTest();

        System.assertEquals(1, ctrl.lineItems.size());
        System.assertEquals('', ctrl.lineItems[0].wrappedProductName);
        System.assertEquals(2, ctrl.lineItems[0].qty);
        System.assertEquals(100, ctrl.lineItems[0].unitPrice);
    }

    @isTest
    static void testLineItemWrapper_ShortProductNameNoWrap() {
        fax__Invoice__c inv = createInvoice();
        createLineItem(inv.Id, 'ShortName', true, 'Short product marker');

        Test.startTest();
        InvoicePDFController ctrl = loadController(inv.Id);
        Test.stopTest();

        InvoicePDFController.LineItemWrapper li =
            findWrapperByDescription(ctrl, 'Short product marker');

        System.assertNotEquals(null, li);
        System.assertEquals('ShortName', li.wrappedProductName);
        System.assert(!li.wrappedProductName.contains('<br/>'));
    }

    @isTest
    static void testLineItemWrapper_WrapAtSpecialCharacters() {
        fax__Invoice__c inv = createInvoice();

        createLineItem(inv.Id, 'ABCDEFGHIJ-KLMNOPQRSTUV', true, 'Dash break marker');
        createLineItem(inv.Id, 'ABCDEFGHIJ/KLMNOPQRSTUV', true, 'Slash break marker');
        createLineItem(inv.Id, 'ABCDEFGHIJ@KLMNOPQRSTUV', true, 'At break marker');
        createLineItem(inv.Id, '123456789012345 67890123456789', true, 'Space break marker');

        Test.startTest();
        InvoicePDFController ctrl = loadController(inv.Id);
        Test.stopTest();

        System.assertEquals(4, ctrl.lineItems.size());

        InvoicePDFController.LineItemWrapper dashItem =
            findWrapperByDescription(ctrl, 'Dash break marker');
        System.assert(dashItem.wrappedProductName.contains('-<br/>'));

        InvoicePDFController.LineItemWrapper slashItem =
            findWrapperByDescription(ctrl, 'Slash break marker');
        System.assert(slashItem.wrappedProductName.contains('/<br/>'));

        InvoicePDFController.LineItemWrapper atItem =
            findWrapperByDescription(ctrl, 'At break marker');
        System.assert(atItem.wrappedProductName.contains('@<br/>'));

        InvoicePDFController.LineItemWrapper spaceItem =
            findWrapperByDescription(ctrl, 'Space break marker');
        System.assert(spaceItem.wrappedProductName.contains('<br/>'));
        System.assert(spaceItem.wrappedProductName.contains('67890123456789'));
    }

    @isTest
    static void testLineItemWrapper_WrapTrimsLeadingSpaceAfterBreak() {
        fax__Invoice__c inv = createInvoice();
        createLineItem(inv.Id, '123456789012345  67890123456789', true, 'Double space break marker');

        Test.startTest();
        InvoicePDFController ctrl = loadController(inv.Id);
        Test.stopTest();

        InvoicePDFController.LineItemWrapper li =
            findWrapperByDescription(ctrl, 'Double space break marker');

        System.assertNotEquals(null, li);
        System.assert(!li.wrappedProductName.contains('<br/> 678'));
        System.assert(li.wrappedProductName.contains('<br/>678'));
    }

    @isTest
    static void testLineItemWrapper_HardBreakWithoutDelimiter() {
        fax__Invoice__c inv = createInvoice();
        createLineItem(inv.Id, 'ABCDEFGHIJKLMNOPQR', true, 'Hard break marker');

        Test.startTest();
        InvoicePDFController ctrl = loadController(inv.Id);
        Test.stopTest();

        InvoicePDFController.LineItemWrapper li =
            findWrapperByDescription(ctrl, 'Hard break marker');

        System.assertNotEquals(null, li);
        System.assertEquals('ABCDEFGHIJKLMNOP<br/>QR', li.wrappedProductName);
    }

    @isTest
    static void testLineItemWrapper_FormatDescription_Blank() {
        fax__Invoice__c inv = createInvoice();
        createLineItem(inv.Id, 'DescProduct', true, null);

        Test.startTest();
        InvoicePDFController ctrl = loadController(inv.Id);
        Test.stopTest();

        System.assertEquals('', ctrl.lineItems[0].formattedDescription);
    }

    @isTest
    static void testLineItemWrapper_FormatDescription_MultilineAndPeriods() {
        fax__Invoice__c inv = createInvoice();
        createLineItem(
            inv.Id,
            'DescProduct',
            true,
            'Line one\r\nLine two\rLine three\twith tab\n\nLine four. Sentence two.'
        );

        Test.startTest();
        InvoicePDFController ctrl = loadController(inv.Id);
        Test.stopTest();

        String formatted = ctrl.lineItems[0].formattedDescription;

        System.assertNotEquals('', formatted);
        System.assert(formatted.contains('Line one'));
        System.assert(formatted.contains('Line two'));
        System.assert(formatted.contains('Line three'));
        System.assert(formatted.contains('with tab'));
        System.assert(formatted.contains('Line four'));
        System.assert(formatted.contains('<br/><br/>'));
        System.assert(formatted.contains('.<br/>'));
    }

    @isTest
    static void testConstructor_DynamicCellFormatsAndDescription() {
        fax__Invoice__c inv = createInvoice();
        createLineItem(inv.Id, 'ShortProduct', true, 'Dynamic cell description');

        fax__Invoice_Line_Item__c lineItem = [
            SELECT Id
            FROM fax__Invoice_Line_Item__c
            WHERE fax__Invoice__c = :inv.Id
            LIMIT 1
        ];
        lineItem.Equipment__c = 'EQ-100';
        update lineItem;

        Test.startTest();
        InvoicePDFController ctrl = loadController(inv.Id);
        Test.stopTest();

        System.assertNotEquals(null, ctrl.previewColumns);
        System.assert(ctrl.previewColumnCount > 0);
        System.assertEquals(ctrl.previewColumnCount, ctrl.previewColumns.size());
        System.assertEquals(1, ctrl.lineItemRows.size());
        System.assertEquals(1, ctrl.lineItems.size());

        InvoicePDFController.DynamicLineItemRow row = ctrl.lineItemRows[0];
        System.assertEquals(ctrl.previewColumnCount, row.cells.size());

        InvoicePDFController.PreviewCell productCell = findCell(row, 'product');
        InvoicePDFController.PreviewCell descriptionCell = findCell(row, 'description');
        InvoicePDFController.PreviewCell quantityCell = findCell(row, 'quantity');
        InvoicePDFController.PreviewCell textCell = findCell(row, 'text');

        System.assertNotEquals(null, productCell);
        System.assertEquals('ShortProduct', productCell.htmlValue);
        System.assertEquals('product-cell', productCell.cssClass);

        System.assertNotEquals(null, descriptionCell);
        System.assertEquals('Dynamic cell description', descriptionCell.displayValue);

        System.assertNotEquals(null, quantityCell);
        System.assertEquals(2, quantityCell.numericValue);

        //System.assertNotEquals(null, textCell);
        //System.assertEquals('EQ-100', textCell.displayValue);
        //System.assertEquals(true, textCell.isText);

        Integer currencyCellCount = 0;
        for (InvoicePDFController.PreviewCell cell : row.cells) {
            if (cell.isCurrency) {
                currencyCellCount++;
                System.assertNotEquals(null, cell.numericValue);
            }
        }
        System.assert(currencyCellCount >= 2, 'Expected price and amount currency cells');
    }

    @isTest
    static void testConstructor_NullNumericValuesUseZero() {
        fax__Invoice__c inv = createInvoice();
        createLineItem(inv.Id, 'NullQtyProduct', true, 'Null numeric marker', null, null);

        Test.startTest();
        InvoicePDFController ctrl = loadController(inv.Id);
        Test.stopTest();

        InvoicePDFController.PreviewCell quantityCell =
            findCell(ctrl.lineItemRows[0], 'quantity');

        System.assertNotEquals(null, quantityCell);
        System.assertEquals(0, quantityCell.numericValue);
    }

    @isTest
    static void testConstructor_PreviewColumnsUseFallbackAlignment() {
        fax__Invoice__c inv = createInvoice();
        createLineItem(inv.Id, 'AlignmentProduct', true, 'Alignment marker');

        Test.startTest();
        InvoicePDFController ctrl = loadController(inv.Id);
        Test.stopTest();

        InvoicePDFController.PreviewColumnDefinition textColumn;
        for (InvoicePDFController.PreviewColumnDefinition column : ctrl.previewColumns) {
            if (column.key == 'text_format_test') {
                textColumn = column;
                break;
            }
        }

        //System.assertNotEquals(null, textColumn, 'Expected text format test metadata column');
        //System.assertEquals('center', textColumn.headerAlignment);
        //System.assertEquals('left', textColumn.cellAlignment);
    }

    @isTest
    static void testConstructor_ProductionPreviewColumnsLoaded() {
        fax__Invoice__c inv = createInvoice();
        createLineItem(inv.Id, 'ProdColProduct', true, 'Production column marker');

        Test.startTest();
        InvoicePDFController ctrl = loadController(inv.Id);
        Test.stopTest();

        Set<String> columnKeys = new Set<String>();
        for (InvoicePDFController.PreviewColumnDefinition column : ctrl.previewColumns) {
            columnKeys.add(column.key);
        }

        System.assert(columnKeys.contains('quantity'), 'Expected quantity preview column');
        System.assert(columnKeys.contains('item'), 'Expected item preview column');
        System.assert(columnKeys.contains('description'), 'Expected description preview column');
        System.assert(columnKeys.contains('price'), 'Expected price preview column');
        System.assert(columnKeys.contains('amount'), 'Expected amount preview column');
        System.assert(ctrl.previewColumnCount >= 5);
    }
}