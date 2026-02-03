#!/usr/bin/env python3
import csv
import io

def extract_and_convert():
    # Read original export
    with open("/Users/naresh/staysecure-hub/deploy/backups/auth-data-only.sql", "r") as f:
        content = f.read()
    
    # Find users section
    users_start = content.find("COPY auth.users")
    users_end = content.find("\\\.", users_start)
    
    if users_start == -1 or users_end == -1:
        print("Could not find users section")
        return
    
    # Extract users COPY line and data
    users_section = content[users_start:users_end]
    lines = users_section.split("\n")
    
    copy_line = lines[0]
    data_lines = [l.strip() for l in lines[1:] if l.strip() and not l.strip().startswith("--")]
    
    # Remove instance_id from COPY statement
    copy_line = copy_line.replace("instance_id, ", "").replace("(instance_id,", "(")
    
    # Update COPY to use CSV format
    if "FROM stdin" in copy_line:
        copy_line = copy_line.replace("FROM stdin;", 'FROM stdin WITH (FORMAT csv, HEADER false, NULL \'\\N\');')
    
    # Process data lines - convert tab to CSV
    output_lines = [copy_line]
    
    for line in data_lines:
        if line == "\\\.\\":
            continue
        
        # Split by tab
        parts = line.split("\t")
        
        # Remove first column (instance_id UUID)
        if parts and len(parts) > 1:
            parts = parts[1:]
        
        # Replace \N with empty string
        parts = ["" if p == "\\N" else p for p in parts]
        
        # Use csv.writer for proper CSV formatting
        output = io.StringIO()
        writer = csv.writer(output, quoting=csv.QUOTE_MINIMAL)
        writer.writerow(parts)
        csv_line = output.getvalue().rstrip("\n\r")
        output_lines.append(csv_line)
    
    output_lines.append("\\.")
    
    # Find identities section
    identities_start = content.find("COPY auth.identities")
    identities_end = content.find("\\\.", identities_start)
    
    if identities_start != -1 and identities_end != -1:
        identities_section = content[identities_start:identities_end]
        id_lines = identities_section.split("\n")
        
        id_copy_line = id_lines[0]
        id_data_lines = [l.strip() for l in id_lines[1:] if l.strip() and not l.strip().startswith("--")]
        
        # Update COPY to use CSV format
        if "FROM stdin" in id_copy_line:
            id_copy_line = id_copy_line.replace("FROM stdin;", 'FROM stdin WITH (FORMAT csv, HEADER false, NULL \'\\N\');')
        
        output_lines.append("")
        output_lines.append("")
        output_lines.append(id_copy_line)
        
        for line in id_data_lines:
            if line == "\\\.\\":
                continue
            
            parts = line.split("\t")
            parts = ["" if p == "\\N" else p for p in parts]
            
            output = io.StringIO()
            writer = csv.writer(output, quoting=csv.QUOTE_MINIMAL)
            writer.writerow(parts)
            csv_line = output.getvalue().rstrip("\n\r")
            output_lines.append(csv_line)
        
        output_lines.append("\\.")
    
    # Write output
    with open("/Users/naresh/staysecure-hub/deploy/backups/auth-users-clean.sql", "w") as f:
        f.write("\n".join(output_lines))
        f.write("\n")
    
    print("✅ Created auth-users-clean.sql")
    print(f"   - Removed instance_id from COPY statement")
    print(f"   - Removed instance_id column (first column) from all user rows")
    print(f"   - Converted tab-delimited to comma-delimited CSV")
    print(f"   - Replaced \\N with empty strings (NULL in CSV)")
    print(f"   - Processed {len([l for l in data_lines if l])} user rows")
    if identities_start != -1:
        print(f"   - Processed {len([l for l in id_data_lines if l])} identity rows")

if __name__ == "__main__":
    extract_and_convert()

