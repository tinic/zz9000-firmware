#ifndef MOCK_SLEEP_H
#define MOCK_SLEEP_H
static inline void usleep_mock_noop(void) {}
#define usleep(x) ((void)(x))
#define sleep(x)  ((void)(x))
#endif
