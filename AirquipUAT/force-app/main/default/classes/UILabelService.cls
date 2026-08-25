/**
 * @description Service class to provide UI labels for components
 * @author FieldAx Team
 * @date 2025
 */
public with sharing class UILabelService {
    
    /**
     * @description Returns all labels needed for JobItemSelector component
     * @return Map<String, String> Key-value pairs of label keys and their values
     */
    @AuraEnabled(cacheable=true)
    public static Map<String, String> getJobItemSelectorLabels() {
        return new Map<String, String>{
            // Header and Navigation
            'cancelAltText' => Label.JobItemSelector_Cancel_Alt_Text,
            'cancelTitle' => Label.JobItemSelector_Cancel_Title,
            'changePricebookLabel' => Label.JobItemSelector_Change_Pricebook_Label,
            'changePricebookTitle' => Label.JobItemSelector_Change_Pricebook_Title,
            'previousLabel' => Label.JobItemSelector_Previous_Label,
            'previousTitle' => Label.JobItemSelector_Previous_Title,
            'nextLabel' => Label.JobItemSelector_Next_Label,
            'nextTitle' => Label.JobItemSelector_Next_Title,
            'saveLabel' => Label.JobItemSelector_Save_Label,
            'saveTitle' => Label.JobItemSelector_Save_Title,
            
            // Pricebook Section
            'selectPricebookTitle' => Label.JobItemSelector_Select_Pricebook_Title,
            'choosePricebookLabel' => Label.JobItemSelector_Choose_Pricebook_Label,
            
            // Product Search Section
            'searchProductsPlaceholder' => Label.JobItemSelector_Search_Products_Placeholder,
            'searchLabel' => Label.JobItemSelector_Search_Label,
            'itemsSelectedSingular' => Label.JobItemSelector_Items_Selected_Singular,
            'itemsSelectedPlural' => Label.JobItemSelector_Items_Selected_Plural,
            'itemsSelectedText' => Label.JobItemSelector_Items_Selected_Text,
            
            // Product Details Section
            'quantityLabel' => Label.JobItemSelector_Quantity_Label,
            'listPriceLabel' => Label.JobItemSelector_List_Price_Label,
            'unitPriceLabel' => Label.JobItemSelector_Unit_Price_Label,
            'discountLabel' => Label.JobItemSelector_Discount_Label,
            
            // Pagination Section
            'showingText' => Label.JobItemSelector_Showing_Text,
            'ofText' => Label.JobItemSelector_Of_Text,
            'itemsText' => Label.JobItemSelector_Items_Text,
            'firstPageAltText' => Label.JobItemSelector_First_Page_Alt_Text,
            'firstPageTitle' => Label.JobItemSelector_First_Page_Title,
            'previousPageAltText' => Label.JobItemSelector_Previous_Page_Alt_Text,
            'previousPageTitle' => Label.JobItemSelector_Previous_Page_Title,
            'pageText' => Label.JobItemSelector_Page_Text,
            'nextPageAltText' => Label.JobItemSelector_Next_Page_Alt_Text,
            'nextPageTitle' => Label.JobItemSelector_Next_Page_Title,
            'lastPageAltText' => Label.JobItemSelector_Last_Page_Alt_Text,
            'lastPageTitle' => Label.JobItemSelector_Last_Page_Title
        };
    }
    
}