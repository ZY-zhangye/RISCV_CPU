#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>

#define MAX_LINE_LEN 128
#define MAX_PATH_LEN 260
#define TEMP_EXT ".tmp"

// 按每8字符（32位）小端逆序
void endian_convert(const char* src, char* dest) {
    // src 应为8字符的十六进制字符串
    if (strlen(src) < 8) {
        strcpy(dest, src); // 不足8直接返回
        return;
    }
    // 逆序
    dest[0] = src[6]; dest[1] = src[7];
    dest[2] = src[4]; dest[3] = src[5];
    dest[4] = src[2]; dest[5] = src[3];
    dest[6] = src[0]; dest[7] = src[1];
    dest[8] = '\0';
}

void process_file(const char* filename) {
    FILE *fin, *ftmp;
    char tmpfile[MAX_PATH_LEN];
    char line[MAX_LINE_LEN];
    char conv[MAX_LINE_LEN];

    // 生成临时文件名
    snprintf(tmpfile, sizeof(tmpfile), "%s%s", filename, TEMP_EXT);

    fin = fopen(filename, "r");
    if (!fin) return;

    ftmp = fopen(tmpfile, "w");
    if (!ftmp) { fclose(fin); return; }

    while (fgets(line, sizeof(line), fin)) {
        // 删除换行和空格
        char* p = line;
        char buf[16] = {0}, idx = 0;
        while (*p && *p != '\n' && idx < 8) {
            if (*p != ' ') buf[idx++] = *p;
            p++;
        }
        buf[idx] = '\0';
        endian_convert(buf, conv);
        fprintf(ftmp, "%s\n", conv);
    }

    fclose(fin);
    fclose(ftmp);

    // 用转换内容覆盖原文件
    remove(filename);
    rename(tmpfile, filename);
}

int main() {
    DIR *d = opendir(".");
    struct dirent *entry;

    if (!d) {
        printf("Failed to open current directory.\n");
        return 1;
    }

    while ((entry = readdir(d)) != NULL) {
        int len = strlen(entry->d_name);
        if (len > 4 && strcmp(entry->d_name + len - 4, ".hex") == 0) {
            printf("Processing %s ...\n", entry->d_name);
            process_file(entry->d_name);
            printf("Converted %s.\n", entry->d_name);
        }
    }
    closedir(d);

    printf("All files have been converted.\n");
    return 0;
}