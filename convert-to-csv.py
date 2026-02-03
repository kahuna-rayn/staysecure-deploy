#!/usr/bin/env python3
import re
import csv
import io

def convert_to_csv(file_path):
    with open(file_path, "r") as f:
        content = f.read()
    
    output_lines = []
    lines = content.split("\n")
    in_users_section = False
    in_identities_section = False
    
    for line in lines:
        # Handle users COPY statement
        if line.startswith("COPY auth.users"):
            # Remove instance_id from column list
            line = re.sub(r'instance_id,\s*', '', line)
            output_lines.append(line)
            in_users_section = True
            in_identities_section = False
            continue
        
        # Handle identities COPY statement
        if line.startswith("COPY auth.identities"):
            output_lines.append(line)
            in_users_section = False
            in_identities_section = True
            continue
        
        # Handle end of data sections
        if line.strip() == "\\.":
            output_lines.append(line)
            in_users_section = False
            in_identities_section = False
            continue
        
        # Handle data rows
        if in_users_section or in_identities_section:
            line = line.strip()
            if not line or line.startswith("--"):
                continue
            
            # Split by tab
            parts = line.split("\t")
            
            # For users section, remove first column if it's INSTANCE_ID_PLACEHOLDER
            if in_users_section and parts and parts[0] == "INSTANCE_ID_PLACEHOLDER":
                parts = parts[1:]
            
            # Replace \N with empty string (NULL in CSV)
            parts = ["" if p == "\\N" else p for p in parts]
            
            # Use csv.writer to properly format CSV with proper quoting
            output = io.StringIO()
            writer = csv.writer(output, quoting=csv.QUOTE_MINIMAL)
            writer.writerow(parts)
            csv_line = output.getvalue().rstrip("\n\r")
            output_lines.append(csv_line)
        else:
            # Keep other lines as-is
            output_lines.append(line)
    
    # Write output
    with open(file_path, "w") as f:
        f.write("\n".join(output_lines))
        if not output_lines[-1].endswith("\n"):
            f.write("\n")
    
    print(f"✅ Converted {file_path} to CSV format")
    print(f"   - Removed instance_id from COPY statement")
    print(f"   - Removed INSTANCE_ID_PLACEHOLDER from all data rows")
    print(f"   - Converted tab-delimited to comma-delimited CSV")
    print(f"   - Replaced \\N with empty strings (NULL in CSV)")

if __name__ == "__main__":
    convert_to_csv("/Users/naresh/staysecure-hub/deploy/backups/auth-users-clean.sql")
