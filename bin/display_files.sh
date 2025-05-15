#!/bin/zsh

# Help function
show_help() {
    cat << EOF
Usage: $(basename $0) [options] FILE
Display a file as Quarto markdown with syntax highlighting.

Options:
    -h, --help              Show this help message
    -l, --lang STRING       Language for syntax highlighting [default: auto-detect]
    -n, --numbers          Add line numbers [default: false]
    -t, --title STRING     Add a title [default: filename]

Example:
    $(basename $0) --lang java --numbers MyClass.java
EOF
}

# Default values
NUMBERS=false
TITLE=""
LANG=""  # Declare LANG with empty default value

# Convert string to valid ID (lowercase, no spaces, no special chars)
to_valid_id() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | tr -c '[:alnum:]' '-' | tr -s '-' | sed 's/-$//'
}

# Function to detect language from file extension
detect_language() {
    case "${1:e}" in
        java|gradle)    echo "java" ;;
        py)             echo "python" ;;
        js|jsx)         echo "javascript" ;;
        ts|tsx)         echo "typescript" ;;
        sh|zsh|bash)    echo "bash" ;;
        yml|yaml)       echo "yaml" ;;
        xml)            echo "xml" ;;
        md)             echo "markdown" ;;
        Dockerfile)     echo "dockerfile" ;;
        *)              echo "text" ;;
    esac
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -l|--lang)
            LANG="$2"
            shift 2
            ;;
        -n|--numbers)
            NUMBERS=true
            shift
            ;;
        -t|--title)
            TITLE="$2"
            shift 2
            ;;
        *)
            FILE="$1"
            shift
            ;;
    esac
done

# Check if file exists
if [[ ! -f "$FILE" ]]; then
    echo "Error: File '$FILE' not found" >&2
    exit 1
fi

# Auto-detect language if not specified
if [[ -z "$LANG" ]]; then
    LANG=$(detect_language "$FILE")
fi

# Use filename as title if not specified
if [[ -z "$TITLE" ]]; then
    TITLE=$(basename "$FILE")
fi

# Generate Quarto markdown
cat << EOF
\`\`\`{.${LANG}${NUMBERS:+ code-line-numbers="true" lst-label="lst-${LANG}-$(to_valid_id $TITLE)" lst-cap="${TITLE}" }}
$(cat "$FILE")
\`\`\`
EOF

