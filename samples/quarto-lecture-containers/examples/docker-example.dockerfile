FROM eclipse-temurin:25-jdk-alpine

# Set working directory
WORKDIR /app

# Copy Java source
COPY HelloWorld.java .

# Compile Java code
RUN javac HelloWorld.java

# Run the application
CMD ["java", "HelloWorld"]
