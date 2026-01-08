public class DataProcessor {
    public static void main(String[] args) {
        System.out.println("Processing data with Java 25...");

        // Using Java 21+ features
        var numbers = java.util.stream.IntStream
            .rangeClosed(1, 10)
            .boxed()
            .toList();

        System.out.println("Numbers: " + numbers);

        var sum = numbers.stream()
            .mapToInt(Integer::intValue)
            .sum();

        var avg = numbers.stream()
            .mapToInt(Integer::intValue)
            .average()
            .orElse(0.0);

        System.out.printf("Sum: %d, Average: %.2f%n", sum, avg);

        // Pattern matching example
        Object obj = "Hello, Java 25!";
        switch (obj) {
            case String s -> System.out.println("String length: " + s.length());
            case Integer i -> System.out.println("Integer value: " + i);
            default -> System.out.println("Unknown type");
        }
    }
}
