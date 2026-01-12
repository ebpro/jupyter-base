public class HelloWorld {
    public static void main(String[] args) {
        System.out.println("Hello from Docker!");
        System.out.println("Java Version: " + System.getProperty("java.version"));
        System.out.println("Running in container: " +
            (System.getenv("container") != null ? "Yes" : "Maybe"));
    }
}
