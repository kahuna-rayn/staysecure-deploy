#!/usr/bin/env python3
import re

def convert_copy_to_insert(file_path):
    with open(file_path, "r") as f:
        content = f.read()
    
    # Extract COPY statement for users
    copy_match = re.search(r"COPY auth\.users \((.+?)\) FROM stdin;", content, re.DOTALL)
    if not copy_match:
        print("Could not find COPY statement for users")
        return
    
    columns = [col.strip() for col in copy_match.group(1).split(",")]
    
    # Extract data rows (between COPY and \.)
    data_start = content.find("FROM stdin;") + len("FROM stdin;")
    data_end = content.find("\\\\.", data_start)
    if data_end == -1:
        data_end = content.find("\n\n", data_start)
    data_section = content[data_start:data_end]
    
    # Generate INSERT statements
    inserts = []
    inserts.append("-- Insert users into auth.users")
    inserts.append("INSERT INTO auth.users (" + ", ".join(columns) + ") VALUES")
    
    lines = [line.strip() for line in data_section.strip().split("\n") if line.strip() and not line.startswith("--")]
    values_list = []
    
    for line in lines:
        if line.startswith("\\."):
            break
        # Split by tab
        parts = line.split("\t")
        if len(parts) < len(columns):
            continue
            
        values = []
        for i, part in enumerate(parts[:len(columns)]):
            if part == "\\N":
                values.append("NULL")
            elif i == 0:  # UUID - first column (id)
                values.append(f"'{part}'::uuid")
            elif columns[i] in ["raw_app_meta_data", "raw_user_meta_data"]:  # JSON columns
                # Escape single quotes in JSON
                escaped = part.replace("'", "''")
                values.append(f"'{escaped}'::jsonb")
            else:
                # Escape single quotes
                escaped = part.replace("'", "''")
                values.append(f"'{escaped}'")
        
        if values:
            values_list.append("(" + ", ".join(values) + ")")
    
    inserts.append(",\n".join(values_list) + ";")
    
    # Now do the same for identities
    copy_identities_match = re.search(r"COPY auth\.identities \((.+?)\) FROM stdin;", content, re.DOTALL)
    if copy_identities_match:
        id_columns = [col.strip() for col in copy_identities_match.group(1).split(",")]
        id_data_start = content.find("COPY auth.identities", copy_match.end())
        id_data_start = content.find("FROM stdin;", id_data_start) + len("FROM stdin;")
        id_data_end = content.find("\\\\.", id_data_start)
        if id_data_end == -1:
            id_data_end = len(content)
        id_data_section = content[id_data_start:id_data_end]
        
        id_inserts = []
        id_inserts.append("\n-- Insert identities into auth.identities")
        id_inserts.append("INSERT INTO auth.identities (" + ", ".join(id_columns) + ") VALUES")
        
        id_lines = [line.strip() for line in id_data_section.strip().split("\n") if line.strip() and not line.startswith("--")]
        id_values_list = []
        
        for line in id_lines:
            if line.startswith("\\."):
                break
            parts = line.split("\t")
            if len(parts) < len(id_columns):
                continue
                
            values = []
            for i, part in enumerate(parts[:len(id_columns)]):
                if part == "\\N":
                    values.append("NULL")
                elif id_columns[i] == "user_id" or id_columns[i] == "id":  # UUID columns
                    values.append(f"'{part}'::uuid")
                elif id_columns[i] == "identity_data":  # JSON column
                    escaped = part.replace("'", "''")
                    values.append(f"'{escaped}'::jsonb")
                else:
                    escaped = part.replace("'", "''")
                    values.append(f"'{escaped}'")
            
            if values:
                id_values_list.append("(" + ", ".join(values) + ")")
        
        id_inserts.append(",\n".join(id_values_list) + ";")
        inserts.extend(id_inserts)
    
    # Build new content
    header = content[:copy_match.start()]
    footer = content[data_end+3:] if data_end != -1 else ""
    
    new_content = header + "\n".join(inserts) + "\n" + footer
    
    with open(file_path, "w") as f:
        f.write(new_content)
    
    print(f"Converted COPY to INSERT statements in {file_path}")

if __name__ == "__main__":
    convert_copy_to_insert("backups/auth-users-clean.sql")

