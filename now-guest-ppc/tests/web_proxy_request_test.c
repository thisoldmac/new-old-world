#include "web_proxy_request.h"

#include <assert.h>
#include <string.h>

int main(void)
{
    char method[8], target[2049];
    const char *proxy =
        "GET https://example.com/path?q=1 HTTP/1.0\r\nHost: example.com\r\n\r\n";
    const char *head = "HEAD /page?token=a&n=2 HTTP/1.1\r\n\r\n";
    const char *connect = "CONNECT example.com:443 HTTP/1.0\r\n\r\n";

    assert(now_web_proxy_parse_request(proxy, strlen(proxy), method,
        sizeof method, target, sizeof target) == kNowWebRequestReady);
    assert(strcmp(method, "GET") == 0);
    assert(strcmp(target, "https://example.com/path?q=1") == 0);
    assert(now_web_proxy_parse_request(head, strlen(head), method,
        sizeof method, target, sizeof target) == kNowWebRequestReady);
    assert(strcmp(method, "HEAD") == 0);
    assert(now_web_proxy_parse_request(connect, strlen(connect), method,
        sizeof method, target, sizeof target) == kNowWebRequestInvalid);
    assert(now_web_proxy_parse_request(proxy, 12, method, sizeof method,
        target, sizeof target) == kNowWebRequestIncomplete);
    return 0;
}
