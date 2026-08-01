import hashlib
import os, os.path
import getpass
import getopt
import sys
import base64
import secrets

#
# The file format of the exported config file is basically an OpenSSL-encrypted
# tgz archive with some extra bits of information interleaved in. As it uses
# `openssl enc -a ...` to encrypt the archive, the exported file is multiple
# lines of Base64 data, laid out like so:
#
# [1] Header - concatenated MD5 hex strings of two device-specific parameters,
#              appears to be comprised of the device model and some MAC address?
# [2...9] Encrypted data
# [10] File hash - 0-32 is random data, 32-64 is an MD5 hash of the encrypted data
# [11...] Rest of the file
# [end] 64 ='s
#

PASSWORD_BASE = 'pIVWb7ovezIB0/5n5s4oLg=='


def usage():
    print('Usage: arcadyan_util [-d(ecrypt) or -e(ncrypt)] [-p factory main WiFi password] path_to_input path_to_output')
    print('If -p is omitted, you will be prompted to enter it.')
    print()
    sys.exit(2)


def decrypt_config(input_path, password, output_path):
    try:
        os.mkdir(output_path)
    except FileExistsError:
        pass
    with open(input_path, 'rb') as fp:
        lines = []
        for line in fp.readlines():
            if line.startswith(b'===') or len(line) == 0:
                break
            lines.append(line)
    
    header = lines[0]

    header_path = os.path.join(output_path, 'header.bin')
    with open(header_path, 'wb') as fp:
        fp.write(header)
    
    contents_enc_path = os.path.join(output_path, 'config.tgz.enc')
    with open(contents_enc_path, 'wb') as fp:
        fp.write(b''.join(lines[1:9]))
        fp.write(b''.join(lines[10:]))
    
    contents_path = os.path.join(output_path, 'config.tgz')
    os.system(f'openssl enc -aes-256-cbc -salt -d -a -in {contents_enc_path} -out {contents_path} -pass pass:{PASSWORD_BASE}{password}')
    print('Decryption complete!')


def encrypt_config(input_path, password, output_path):
    header_path = os.path.join(input_path, 'header.bin')
    with open(header_path, 'rb') as fp:
        header = fp.readline()
    
    contents_path = os.path.join(input_path, 'config.tgz')    
    contents_enc_path = os.path.join(input_path, 'config.tgz.enc')
    os.system(f'openssl enc -aes-256-cbc -salt -a -in {contents_path} -out {contents_enc_path} -pass pass:{PASSWORD_BASE}{password}')

    with open(contents_enc_path, 'rb') as fp:
        md5 = hashlib.md5()
        for chunk in iter(lambda: fp.read(4096), b''):
            md5.update(chunk)
        contents_hash = md5.hexdigest().encode()
        garbage = base64.b64encode(secrets.token_bytes(24))

    with open(contents_enc_path, 'rb') as contents_fp:
        with open(output_path, 'wb') as out_fp:
            line_num = 1
            line = contents_fp.readline()
            while line:
                if line_num == 1:
                    out_fp.write(header)
                    line_num += 1
                elif line_num == 10:
                    out_fp.write(garbage + contents_hash + b'\n')
                    line_num += 1
                out_fp.write(line)
                line = contents_fp.readline()
                line_num += 1
            out_fp.write((b'=' * 64) + b'\n')
    print('Encryption complete!')


def main():
    print('Decryptor/encryptor for Arcadyan/Spark/Skinny VRV9517 router')
    try:
        opts, args = getopt.getopt(sys.argv[1:], 'dep:')
    except getopt.GetoptError as err:
        print(err)
        usage()
    
    if len(args) < 2:
        usage()

    for o, a in opts:
        if o == '-d':
            mode = 'decrypt'
        elif o == '-e':
            mode = 'encrypt'
        elif o == '-p':
            password = a
    
    if password is None:
        password = getpass.getpass('Enter the factory WiFi password: ')
        if password is None:
            exit(-1)
    
    password = hashlib.md5(password.encode()).hexdigest()
    
    if mode == 'encrypt':
        encrypt_config(args[0], password, args[1])
    else:
        decrypt_config(args[0], password, args[1])          


if __name__ == "__main__":
    main()
