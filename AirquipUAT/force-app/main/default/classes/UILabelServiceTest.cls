@isTest
private class UILabelServiceTest {

    // ── getJobItemSelectorLabels ───────────────────────────────────────────

    @isTest
    static void testGetJobItemSelectorLabels_returnsNonNullMap() {
        Test.startTest();
        Map<String, String> labels = UILabelService.getJobItemSelectorLabels();
        Test.stopTest();

        System.assertNotEquals(null, labels, 'Returned map should not be null');
    }

    @isTest
    static void testGetJobItemSelectorLabels_correctSize() {
        Test.startTest();
        Map<String, String> labels = UILabelService.getJobItemSelectorLabels();
        Test.stopTest();

        System.assertEquals(33, labels.size(), 'Map should contain exactly 33 label entries');
    }

    // ── Header and Navigation keys ─────────────────────────────────────────

    @isTest
    static void testGetJobItemSelectorLabels_headerAndNavigationKeys() {
        Test.startTest();
        Map<String, String> labels = UILabelService.getJobItemSelectorLabels();
        Test.stopTest();

        List<String> expectedKeys = new List<String>{
            'cancelAltText',
            'cancelTitle',
            'changePricebookLabel',
            'changePricebookTitle',
            'previousLabel',
            'previousTitle',
            'nextLabel',
            'nextTitle',
            'saveLabel',
            'saveTitle'
        };

        for (String key : expectedKeys) {
            System.assert(labels.containsKey(key), 'Map should contain key: ' + key);
            System.assertNotEquals(null, labels.get(key), 'Value for key "' + key + '" should not be null');
        }
    }

    // ── Pricebook Section keys ─────────────────────────────────────────────

    @isTest
    static void testGetJobItemSelectorLabels_pricebookSectionKeys() {
        Test.startTest();
        Map<String, String> labels = UILabelService.getJobItemSelectorLabels();
        Test.stopTest();

        List<String> expectedKeys = new List<String>{
            'selectPricebookTitle',
            'choosePricebookLabel'
        };

        for (String key : expectedKeys) {
            System.assert(labels.containsKey(key), 'Map should contain key: ' + key);
            System.assertNotEquals(null, labels.get(key), 'Value for key "' + key + '" should not be null');
        }
    }

    // ── Product Search Section keys ────────────────────────────────────────

    @isTest
    static void testGetJobItemSelectorLabels_productSearchSectionKeys() {
        Test.startTest();
        Map<String, String> labels = UILabelService.getJobItemSelectorLabels();
        Test.stopTest();

        List<String> expectedKeys = new List<String>{
            'searchProductsPlaceholder',
            'searchLabel',
            'itemsSelectedSingular',
            'itemsSelectedPlural',
            'itemsSelectedText'
        };

        for (String key : expectedKeys) {
            System.assert(labels.containsKey(key), 'Map should contain key: ' + key);
            System.assertNotEquals(null, labels.get(key), 'Value for key "' + key + '" should not be null');
        }
    }

    // ── Product Details Section keys ───────────────────────────────────────

    @isTest
    static void testGetJobItemSelectorLabels_productDetailsSectionKeys() {
        Test.startTest();
        Map<String, String> labels = UILabelService.getJobItemSelectorLabels();
        Test.stopTest();

        List<String> expectedKeys = new List<String>{
            'quantityLabel',
            'listPriceLabel',
            'unitPriceLabel',
            'discountLabel'
        };

        for (String key : expectedKeys) {
            System.assert(labels.containsKey(key), 'Map should contain key: ' + key);
            System.assertNotEquals(null, labels.get(key), 'Value for key "' + key + '" should not be null');
        }
    }

    // ── Pagination Section keys ────────────────────────────────────────────

    @isTest
    static void testGetJobItemSelectorLabels_paginationSectionKeys() {
        Test.startTest();
        Map<String, String> labels = UILabelService.getJobItemSelectorLabels();
        Test.stopTest();

        List<String> expectedKeys = new List<String>{
            'showingText',
            'ofText',
            'itemsText',
            'firstPageAltText',
            'firstPageTitle',
            'previousPageAltText',
            'previousPageTitle',
            'pageText',
            'nextPageAltText',
            'nextPageTitle',
            'lastPageAltText',
            'lastPageTitle'
        };

        for (String key : expectedKeys) {
            System.assert(labels.containsKey(key), 'Map should contain key: ' + key);
            System.assertNotEquals(null, labels.get(key), 'Value for key "' + key + '" should not be null');
        }
    }

    // ── All keys combined ──────────────────────────────────────────────────

    @isTest
    static void testGetJobItemSelectorLabels_allExpectedKeys() {
        Test.startTest();
        Map<String, String> labels = UILabelService.getJobItemSelectorLabels();
        Test.stopTest();

        List<String> allExpectedKeys = new List<String>{
            // Header and Navigation
            'cancelAltText', 'cancelTitle',
            'changePricebookLabel', 'changePricebookTitle',
            'previousLabel', 'previousTitle',
            'nextLabel', 'nextTitle',
            'saveLabel', 'saveTitle',
            // Pricebook Section
            'selectPricebookTitle', 'choosePricebookLabel',
            // Product Search Section
            'searchProductsPlaceholder', 'searchLabel',
            'itemsSelectedSingular', 'itemsSelectedPlural', 'itemsSelectedText',
            // Product Details Section
            'quantityLabel', 'listPriceLabel', 'unitPriceLabel', 'discountLabel',
            // Pagination Section
            'showingText', 'ofText', 'itemsText',
            'firstPageAltText', 'firstPageTitle',
            'previousPageAltText', 'previousPageTitle',
            'pageText',
            'nextPageAltText', 'nextPageTitle',
            'lastPageAltText', 'lastPageTitle'
        };

        for (String key : allExpectedKeys) {
            System.assert(labels.containsKey(key), 'Map is missing expected key: ' + key);
        }
    }

    // ── No unexpected keys ─────────────────────────────────────────────────

    @isTest
    static void testGetJobItemSelectorLabels_noUnexpectedKeys() {
        Test.startTest();
        Map<String, String> labels = UILabelService.getJobItemSelectorLabels();
        Test.stopTest();

        Set<String> knownKeys = new Set<String>{
            'cancelAltText', 'cancelTitle',
            'changePricebookLabel', 'changePricebookTitle',
            'previousLabel', 'previousTitle',
            'nextLabel', 'nextTitle',
            'saveLabel', 'saveTitle',
            'selectPricebookTitle', 'choosePricebookLabel',
            'searchProductsPlaceholder', 'searchLabel',
            'itemsSelectedSingular', 'itemsSelectedPlural', 'itemsSelectedText',
            'quantityLabel', 'listPriceLabel', 'unitPriceLabel', 'discountLabel',
            'showingText', 'ofText', 'itemsText',
            'firstPageAltText', 'firstPageTitle',
            'previousPageAltText', 'previousPageTitle',
            'pageText',
            'nextPageAltText', 'nextPageTitle',
            'lastPageAltText', 'lastPageTitle'
        };

        for (String key : labels.keySet()) {
            System.assert(knownKeys.contains(key), 'Map contains unexpected key: ' + key);
        }
    }

    // ── AuraEnabled cacheable verification (via calling context) ───────────

    @isTest
    static void testGetJobItemSelectorLabels_calledMultipleTimes() {
        // Validates caching-compatible method is idempotent — same result on repeated calls
        Test.startTest();
        Map<String, String> firstCall  = UILabelService.getJobItemSelectorLabels();
        Map<String, String> secondCall = UILabelService.getJobItemSelectorLabels();
        Test.stopTest();

        System.assertEquals(firstCall.size(), secondCall.size(), 'Repeated calls should return the same number of labels');
        System.assertEquals(firstCall.keySet(), secondCall.keySet(), 'Repeated calls should return the same keys');
    }
}