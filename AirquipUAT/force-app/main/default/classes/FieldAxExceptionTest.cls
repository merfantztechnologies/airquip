@isTest
private class FieldAxExceptionTest {

    @isTest
    static void testExceptionThrow() {
        try {
            // Throw the custom exception
            throw new FieldAxException('Test exception');
        } catch (FieldAxException ex) {
            // Validate message
            System.assertEquals('Test exception', ex.getMessage());
        }
    }
}