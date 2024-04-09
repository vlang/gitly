module api

pub struct ApiErrorResponse {
pub:
	success bool
	message string
}

pub struct ApiResponse {
pub:
	success bool
	message string
}

pub struct ApiSuccessResponse[T] {
pub:
	success bool
	result  T
}
